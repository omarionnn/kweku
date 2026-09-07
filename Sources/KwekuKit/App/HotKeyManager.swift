import AppKit
import Carbon.HIToolbox

/// 'kwku' — scopes our IDs so the handler ignores hotkeys we didn't set. File
/// scope rather than a static on the manager: the C callback below is
/// nonisolated and can't read a `@MainActor` type's storage.
private let hotKeySignature = OSType(0x6B77_6B75)

/// System-wide keyboard shortcuts, via the Carbon Event Manager.
///
/// `RegisterEventHotKey` is the only route to a global hotkey that costs no TCC
/// grant. The obvious alternative — `NSEvent.addGlobalMonitorForEvents(matching:
/// .keyDown)` — needs Input Monitoring, which this app declines everywhere else
/// on purpose: `SensorHub` polls `modifierFlags` rather than monitoring them,
/// and `NotchController` skips a global scroll monitor for the same reason.
///
/// It needs no entitlement and no Info.plist key either, so shortcuts live in
/// the dylib and adding one is a `make app`. The frozen host's cdhash never
/// moves and the Screen Recording grant survives.
///
/// The trade: a Carbon hotkey is *consumed*. The frontmost app never sees the
/// keystroke, so a combo claimed here is dead everywhere until Kweku quits.
/// That rules out the common ⌘-letter space — registering ⌘A would kill Select
/// All system-wide. Pick combos no app wants back.
@MainActor
public final class HotKeyManager {
    public static let shared = HotKeyManager()

    /// A combo worth claiming. `label` exists so a failure can name itself in
    /// the log instead of leaving you guessing which one died.
    public struct Shortcut: Sendable {
        public let keyCode: UInt32
        public let modifiers: UInt32
        public let label: String

        public init(keyCode: Int, modifiers: Int, label: String) {
            self.keyCode = UInt32(keyCode)
            self.modifiers = UInt32(modifiers)
            self.label = label
        }

        /// Toggles Kweku Live. Two modifiers rather than three because this is
        /// the one action worth reaching for mid-sentence; ⌥⌘K is unclaimed by
        /// macOS and rare enough in apps to be worth the small risk.
        public static let toggleLive = Shortcut(keyCode: kVK_ANSI_K,
                                                modifiers: optionKey | cmdKey,
                                                label: "⌥⌘K")

        /// Summons the command line: the notch opens with the caret already
        /// blinking, from inside whatever app you were in.
        ///
        /// ⌥Space and not the obvious ⌘Space, which Spotlight owns — claiming
        /// that here would either be refused outright or take Spotlight away
        /// from the whole machine for as long as Kweku runs. ⌥Space costs the
        /// non-breaking space, which is a fair trade for a one-hand summon.
        public static let summonCommand = Shortcut(keyCode: kVK_Space,
                                                   modifiers: optionKey,
                                                   label: "⌥Space")
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    /// Combos already claimed, so a re-entrant `onAppear` can't double-register.
    private var claimed: Set<UInt64> = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    // MARK: - Registration

    /// Claims `shortcut` system-wide, replacing nothing and stealing nothing.
    ///
    /// Returns false when the combo is already spoken for — by macOS or another
    /// running app — which is the failure actually worth knowing about, since
    /// `RegisterEventHotKey` is silent about it and a hotkey that was never
    /// registered looks exactly like an action that's broken.
    @discardableResult
    public func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        let combo = UInt64(shortcut.keyCode) << 32 | UInt64(shortcut.modifiers)
        guard !claimed.contains(combo) else { return true }

        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode,
                                         shortcut.modifiers,
                                         EventHotKeyID(signature: hotKeySignature, id: id),
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)

        guard status == noErr, let ref else {
            ScreenCaptureManager.dbg(
                "hotkey \(shortcut.label) REFUSED (OSStatus \(status)) — already claimed by something else?")
            return false
        }

        actions[id] = action
        refs[id] = ref
        claimed.insert(combo)
        ScreenCaptureManager.dbg("hotkey \(shortcut.label) registered")
        return true
    }

    /// Hands every combo back to the system. Not called in normal operation —
    /// quitting releases them — but keeps the class honest for tests.
    public func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
        claimed.removeAll()
    }

    // MARK: - Dispatch

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, &handler)
    }
}

/// Carbon hands back a bare C function pointer, so this captures nothing and
/// reaches the manager through the shared instance. It runs on the main thread:
/// the application event target is pumped by the main run loop.
private let hotKeyCallback: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &id)
    guard status == noErr, id.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    MainActor.assumeIsolated { HotKeyManager.shared.fire(id.id) }
    return noErr
}
