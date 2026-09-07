import Foundation

/// One thing the notch has to say, on its own initiative.
///
/// Kweku could already tell you an agent had finished — by changing its eyes.
/// That is a signal you have to be looking at the notch to receive, and the
/// whole point of a thing living in your peripheral vision is that you aren't.
/// A drop is the notch extending for a couple of seconds, saying one line, and
/// retracting: the content, not just the fact that there is content.
public struct NotchDrop: Equatable, Identifiable, Sendable {
    /// What the line means, which is all the colour has to encode.
    public enum Tint: Equatable, Sendable {
        /// Something is owed — amber, the colour of anything with a deadline.
        case attention
        /// Finished, nothing owed.
        case done
        /// Neither; a statement of fact.
        case neutral
    }

    /// Dedupe key, normally the session id. A session that speaks twice before
    /// it has been shown replaces itself rather than queueing twice — three
    /// events from one agent is one thing you need to know, not three.
    public var id: String
    public var symbol: String
    public var title: String
    public var detail: String
    public var tint: Tint
    public var dwell: TimeInterval

    public init(id: String, symbol: String, title: String, detail: String,
                tint: Tint, dwell: TimeInterval? = nil) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.tint = tint
        self.dwell = dwell ?? NotchDrop.dwell(for: detail)
    }

    /// How long a line should hang there, from how much there is to read.
    ///
    /// A fixed dwell is wrong at both ends: "waiting on you" sits there long
    /// after it's been read, and a line with a branch name and three counts is
    /// gone before you've parsed it. Bounded at both ends so nothing flashes
    /// and nothing overstays.
    public static func dwell(for detail: String) -> TimeInterval {
        let read = 2.2 + Double(detail.count) * 0.045
        return min(max(read, 2.4), 5.5)
    }

    /// The one line of a block of output worth putting under the cutout.
    ///
    /// A gateway result is whatever length it is, and the notch has room for
    /// about sixty characters. Takes the first line with anything on it —
    /// answers lead, stack traces lead with the failure — and says when it
    /// has cut.
    public static func firstLine(_ text: String, limit: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "…"
    }
}

/// The line of drops waiting to be said.
///
/// Bounded on purpose. Five agents finishing during a build means five things
/// worth knowing and about eighteen seconds of notch, which is no longer a
/// glance — it's a queue you have to wait out. Past the cap the oldest are
/// counted rather than shown, and the count is said at the end.
public struct DropQueue: Equatable {
    /// Drops shown individually before the rest collapse into a count.
    public static let maxPending = 3

    public private(set) var pending: [NotchDrop] = []
    /// How many were dropped on the floor to stay under the cap.
    public private(set) var missed = 0

    public init() {}

    public var isEmpty: Bool { pending.isEmpty && missed == 0 }

    public mutating func enqueue(_ drop: NotchDrop) {
        if let index = pending.firstIndex(where: { $0.id == drop.id }) {
            pending[index] = drop
            return
        }
        pending.append(drop)
        // Keep the newest. An agent that finished four events ago matters less
        // than the one that just did, and the count says none were lost.
        let overflow = pending.count - Self.maxPending
        if overflow > 0 {
            pending.removeFirst(overflow)
            missed += overflow
        }
    }

    /// The next line to say, or nil when there's nothing left. The overflow
    /// count comes last, once the individual ones have had their turn.
    public mutating func take() -> NotchDrop? {
        if !pending.isEmpty { return pending.removeFirst() }
        guard missed > 0 else { return nil }
        let count = missed
        missed = 0
        return NotchDrop(id: "overflow", symbol: "ellipsis",
                         title: "+\(count) more",
                         detail: "hover for the rest", tint: .neutral, dwell: 2.4)
    }

    /// Forget everything queued. Used when the notch is opened by hand — you
    /// are looking at the panel that holds all of it.
    public mutating func clear() {
        pending.removeAll()
        missed = 0
    }
}

/// Whether the notch may speak right now.
///
/// Every one of these is a reason the line would be an interruption rather
/// than a service: you are already looking at it, you are typing into it,
/// it is already saying something out loud, or you have asked it to be quiet.
public struct DropGate: Equatable, Sendable {
    /// Kweku is hidden entirely.
    public var hidden = false
    /// The notch is open under the cursor — whatever the drop would say is
    /// already on screen in the panel.
    public var hovering = false
    /// The command field holds the keyboard. Nothing may move under a caret.
    public var typing = false
    /// A voice session owns the nook and will say it out loud instead.
    public var live = false
    /// Mid-drag; the notch is being used as a drop target.
    public var dragging = false
    /// "Pause notices" — the explicit switch.
    ///
    /// Not macOS Focus: from macOS 13 the Focus state moved out of
    /// `~/Library/DoNotDisturb` and there is no public API for it, so an app
    /// without private entitlements cannot read it. A switch Kweku actually
    /// owns is worth more than a guess at one it doesn't.
    public var muted = false

    public init(hidden: Bool = false, hovering: Bool = false, typing: Bool = false,
                live: Bool = false, dragging: Bool = false, muted: Bool = false) {
        self.hidden = hidden
        self.hovering = hovering
        self.typing = typing
        self.live = live
        self.dragging = dragging
        self.muted = muted
    }

    public var allows: Bool {
        !(hidden || hovering || typing || live || dragging || muted)
    }
}
