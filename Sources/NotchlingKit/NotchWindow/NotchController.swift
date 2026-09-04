import AppKit
import SwiftUI
import Combine

/// Owns the overlay window and wires geometry + hit-testing + sideways drag.
///
/// Deliberately ignorant of *what* it displays: the caller injects a SwiftUI
/// view built from the shared `NotchViewModel`. The content publishes a
/// `desiredSize`; this class sizes the window to it (pinned to the notch's top
/// edge, centred unless mid-slide) and republishes raw interaction signals.
@MainActor
public final class NotchController {
    /// Public so the app layer can build content that also owns its own model.
    public let model = NotchViewModel()

    private let window: OverlayWindow
    private var machine = HitStateMachine()

    private var layout: NotchLayout?
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    // Sideways-drag bookkeeping.
    private var mouseDownInside = false
    private var creatureDragging = false
    private var dragStartMouseX: CGFloat = 0
    private var dragStartWindowX: CGFloat = 0
    private var springHomeWork: DispatchWorkItem?
    private var springTimer: Timer?

    public init(rootView: (NotchViewModel) -> AnyView) {
        window = OverlayWindow(contentRect: CGRect(origin: .zero, size: NotchGeometry.fallbackSize))

        let hosting = NSHostingView(rootView: rootView(model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        window.contentView = hosting

        model.$desiredSize
            .removeDuplicates()
            .sink { [weak self] size in
                MainActor.assumeIsolated {
                    guard let self, !self.creatureDragging else { return }
                    // NOTE: @Published emits on *willSet* — the property still
                    // holds the old value here, so we must use the payload.
                    self.applyWindowSize(desired: size, resetToHome: false)
                }
            }
            .store(in: &cancellables)

        recomputeGeometry()
        installEventMonitors()
        installScreenObserver()
        window.orderFrontRegardless()
    }

    deinit {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        springTimer?.invalidate()
        springHomeWork?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    // MARK: - Geometry

    private func recomputeGeometry() {
        guard let screen = NotchScreenReader.preferredScreen() else { return }
        let metrics = NotchScreenReader.metrics(for: screen)
        let resolved = NotchGeometry.layout(for: metrics)
        layout = resolved
        model.notchSize = resolved.notchRect.size
        model.isSynthetic = resolved.isSynthetic
        cancelSpring()
        applyWindowSize(resetToHome: true)
    }

    /// Size the window to the content's desired size, pinned to the notch's top
    /// edge. `resetToHome` re-centres x; otherwise x is preserved (a slide).
    private func applyWindowSize(desired: CGSize? = nil, resetToHome: Bool) {
        guard let layout else { return }
        let base = layout.notchRect
        let scr = NotchScreenReader.preferredScreen()?.frame ?? base
        let want = desired ?? model.desiredSize
        let target = want == .zero ? base.size : want

        let width = min(target.width, scr.width - 12)
        let height = max(target.height, base.height)
        let homeX = base.midX - width / 2
        // Preserve the window's *centre* (not its left edge) so width changes
        // grow symmetrically around the notch instead of rightward.
        let unclamped = resetToHome ? homeX : window.frame.midX - width / 2
        let originX = clamp(unclamped, minX: scr.minX + 6, maxX: scr.maxX - width - 6)
        let rect = CGRect(x: originX, y: base.maxY - height, width: width, height: height)
        window.setFrame(rect, display: true)
        publishCenter()
    }

    private func publishCenter() {
        model.contentCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
    }

    private func installScreenObserver() {
        // Covers resolution changes AND display connect/disconnect.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recomputeGeometry() }
        }
    }

    // MARK: - Event monitors

    private func installEventMonitors() {
        func global(_ mask: NSEvent.EventTypeMask, _ handler: @escaping () -> Void) {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
                MainActor.assumeIsolated { handler() }
            }) { eventMonitors.append(m) }
        }
        func local(_ mask: NSEvent.EventTypeMask, _ handler: @escaping () -> Void) {
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in
                MainActor.assumeIsolated { handler() }; return e
            }) { eventMonitors.append(m) }
        }

        global(.mouseMoved) { [weak self] in self?.handleMove() }
        local(.mouseMoved) { [weak self] in self?.handleMove() }
        local(.leftMouseDown) { [weak self] in self?.handleDown() }
        global(.leftMouseDragged) { [weak self] in self?.handleDrag() }
        local(.leftMouseDragged) { [weak self] in self?.handleDrag() }
        global(.leftMouseUp) { [weak self] in self?.handleUp() }
        local(.leftMouseUp) { [weak self] in self?.handleUp() }
    }

    private func cursorInsideNotch() -> Bool {
        // Use the window's live frame (it may have slid/grown) so hover tracks
        // the creature and the revealed shelf.
        window.frame.contains(NSEvent.mouseLocation)
    }

    // MARK: - Hover

    private func handleMove() {
        model.globalCursor = NSEvent.mouseLocation
        if machine.cursorMoved(inside: cursorInsideNotch()) { applyState() }
        // Self-heal: passive + off-home + no spring pending -> come home.
        if machine.state == .passive, !creatureDragging,
           springTimer == nil, springHomeWork == nil,
           let layout, abs(window.frame.midX - layout.notchRect.midX) > 1 {
            scheduleSpringHome()
        }
    }

    // MARK: - Sideways drag vs. drop arm

    private func handleDown() {
        // Only content that wants it (the creature) is window-draggable; the
        // music island's scrubber/buttons must never move the window.
        mouseDownInside = model.contentDraggable && cursorInsideNotch()
        if mouseDownInside {
            dragStartMouseX = NSEvent.mouseLocation.x
            dragStartWindowX = window.frame.minX
        }
    }

    private func handleDrag() {
        if mouseDownInside {
            if !creatureDragging {
                creatureDragging = true
                model.isDragging = true
                cancelSpring()   // cancel only when a real drag starts, not on click
            }
            let delta = NSEvent.mouseLocation.x - dragStartMouseX
            guard let scr = NotchScreenReader.preferredScreen()?.frame else { return }
            let newX = clamp(dragStartWindowX + delta,
                             minX: scr.minX + 6, maxX: scr.maxX - window.frame.width - 6)
            window.setFrameOrigin(CGPoint(x: newX, y: window.frame.minY))
            publishCenter()
        } else {
            if machine.dragBegan() { applyState() }
        }
    }

    private func handleUp() {
        if creatureDragging {
            creatureDragging = false
            model.isDragging = false
            scheduleSpringHome()
        } else if machine.state == .dragArmed {
            if machine.dragEnded(insideNow: cursorInsideNotch()) { applyState() }
        }
        mouseDownInside = false
    }

    private func clamp(_ x: CGFloat, minX: CGFloat, maxX: CGFloat) -> CGFloat {
        min(max(x, minX), max(minX, maxX))
    }

    private func applyState() {
        window.ignoresMouseEvents = machine.ignoresMouseEvents
        model.isHovering = machine.state == .hovering
        model.expanded = machine.state == .dragArmed
        applyWindowSize(resetToHome: false)
    }

    // MARK: - Spring home

    private func scheduleSpringHome() {
        springHomeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.springHome() }
        }
        springHomeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func cancelSpring() {
        springHomeWork?.cancel(); springHomeWork = nil
        springTimer?.invalidate(); springTimer = nil
    }

    /// Critically-damped-ish spring returning window.x to the notch home.
    private func springHome() {
        guard let layout else { return }
        springTimer?.invalidate()
        let target = layout.notchRect.midX - window.frame.width / 2
        var x = window.frame.minX
        var v: CGFloat = 0
        let stiffness: CGFloat = 260, damping: CGFloat = 24
        let dt: CGFloat = 1.0 / 60.0

        let timer = Timer(timeInterval: TimeInterval(dt), repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let force = -stiffness * (x - target) - damping * v
                v += force * dt
                x += v * dt
                if abs(x - target) < 0.5 && abs(v) < 2 {
                    x = target; t.invalidate(); self.springTimer = nil
                }
                self.window.setFrameOrigin(CGPoint(x: x, y: self.window.frame.minY))
                self.publishCenter()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }
}
