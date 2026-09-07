import AppKit
import Combine

/// Runs the queue of things the notch says by itself.
///
/// Owns exactly two decisions: whether now is a moment it may speak (the gate),
/// and for how long (the drop's own dwell). Everything about *what* is said
/// comes from whoever posted it.
@MainActor
public final class DropHub: ObservableObject {
    /// The line on screen, if any. Held through the retract animation, so the
    /// panel has something to collapse rather than vanishing mid-motion.
    @Published public private(set) var current: NotchDrop?
    /// False while the current drop is retracting.
    @Published public private(set) var presenting = false
    /// When the current drop appeared. The rim reads its own countdown off
    /// this and the clock — a pure function of time, like the comet, so the
    /// arc can't drift out of step with the retraction it's counting down to.
    @Published public private(set) var shownAt: Date?

    /// The explicit quiet switch, persisted across launches.
    @Published public var muted: Bool = UserDefaults.standard.bool(forKey: DropHub.mutedKey) {
        didSet {
            UserDefaults.standard.set(muted, forKey: Self.mutedKey)
            if muted { retractNow() } else { pump() }
        }
    }

    /// Supplied by the content root: the live answer to "may I speak".
    public var gate: () -> DropGate = { DropGate() }

    private static let mutedKey = "dropsMuted"
    /// How long the shape takes to fold away before the next line may start.
    private static let retractDuration: TimeInterval = 0.28

    private var queue = DropQueue()
    private var work: DispatchWorkItem?

    public init() {}

    // MARK: - Posting

    public func post(_ drop: NotchDrop) {
        queue.enqueue(drop)
        pump()
    }

    /// Present the next line if the moment allows and nothing is on screen.
    ///
    /// Called on every change that could open or close the gate, so a queue
    /// that arrived while you were typing is said when you stop rather than
    /// being lost or waiting for the next event to shake it loose.
    public func pump() {
        guard current == nil, gate().allows, !queue.isEmpty else { return }
        guard let next = queue.take() else { return }
        // Left in behind the debug flag: a drop is a two-second event with no
        // trace afterwards, so "did it fire and what did it say" is otherwise
        // unanswerable after the fact.
        ScreenCaptureManager.dbg("drop: \(next.title) — \(next.detail) (\(next.dwell)s)")
        current = next
        shownAt = Date()
        presenting = true
        schedule(after: next.dwell) { [weak self] in self?.retractNow() }
    }

    /// Something took the notch over — stop talking.
    ///
    /// The line is *not* requeued. Every reason the gate closes is a reason
    /// you are now looking at the notch yourself, and re-saying it over the
    /// panel you just opened would be the notch talking over itself.
    public func interrupt() {
        guard current != nil else { return }
        retractNow()
    }

    /// Opening the notch by hand answers everything queued at once.
    public func clear() {
        queue.clear()
        interrupt()
    }

    // MARK: - Retraction

    private func retractNow() {
        guard current != nil, presenting else { return }
        presenting = false
        schedule(after: Self.retractDuration) { [weak self] in
            guard let self else { return }
            self.current = nil
            self.shownAt = nil
            // Straight on to the next one, if the moment still allows it.
            self.pump()
        }
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated(body) }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
