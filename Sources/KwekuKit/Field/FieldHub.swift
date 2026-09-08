import AppKit
import SwiftUI

/// Owns the Field: the one window Kweku draws outside the cutout, and the
/// decision about whether it should exist right now at all.
///
/// The rule it enforces is the cost rule. A full-screen layer over someone's
/// work is only defensible if it is genuinely absent when there is nothing to
/// say, so "nothing to say" is `orderOut` — not a transparent window left up,
/// not an empty view, not a paused animation. Kweku spends most of the day
/// with no window here.
@MainActor
public final class FieldHub: ObservableObject {

    /// What the border is currently saying.
    @Published public private(set) var glow: EdgeGlow = .none

    /// Supplied by the content root: the live answer to "may I draw".
    public var gate: () -> FieldGate = { FieldGate() }

    private var window: FieldWindow?
    private var shownAt = Date.distantPast
    /// The count as last reported, before the gate had its say. Kept so that
    /// unmuting relights a border for a session that started waiting while the
    /// switch was off — the wait didn't stop happening.
    private var owed = 0
    private var screenObserver: NSObjectProtocol?

    public init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followScreen() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    // MARK: - Input

    /// How many sessions have stopped and need Omari.
    public func report(owed count: Int) {
        let count = max(0, count)
        guard count != owed else { return }
        // A *second* agent getting stuck is news, so the border breathes again;
        // one of four being answered is not, so it merely gets thinner. Rising
        // and falling are not the same event and shouldn't look alike.
        let rising = count > owed
        owed = count
        apply(relight: rising)
    }

    /// Re-evaluate against a gate that may have changed under us.
    public func refresh() { apply(relight: false) }

    // MARK: - Resolution

    private func apply(relight: Bool) {
        let want: EdgeGlow = (gate().allows && owed > 0) ? .owed(sessions: owed) : .none
        guard want != glow || relight else { return }

        let wasLit = glow.isLit
        glow = want

        guard want.isLit else {
            window?.orderOut(nil)
            return
        }
        // Only restart the motion when there's something new to notice.
        // Re-lighting on every thickness change would mean four agents
        // finishing over ten minutes breathing the border four times.
        if relight || !wasLit { shownAt = Date() }
        present()
    }

    private func present() {
        let window = ensureWindow()
        window.show(glow: glow, shownAt: shownAt)
        window.orderFrontRegardless()
    }

    private func ensureWindow() -> FieldWindow {
        if let window { return window }
        let screen = NotchScreenReader.preferredScreen() ?? NSScreen.main ?? NSScreen.screens[0]
        let created = FieldWindow(screen: screen)
        window = created
        return created
    }

    /// Displays came and went. The Field follows the same screen the notch
    /// does — it is Kweku's own border, not the focused window's.
    private func followScreen() {
        guard let window, let screen = NotchScreenReader.preferredScreen() ?? NSScreen.main
        else { return }
        window.follow(screen: screen)
    }
}
