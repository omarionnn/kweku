import Foundation

/// Where a Live session is in its lifecycle.
///
/// Split out of the old free-text `status` string, which was carrying two
/// unrelated things at once: the connection lifecycle *and* screen-capture
/// failures. A vision issue would overwrite "live", so the one line telling you
/// the session was healthy vanished the moment the screen stopped working —
/// exactly when you most needed to know the socket was still up. Vision now has
/// its own axis in `LiveVision`.
public enum LivePhase: Equatable, Sendable {
    case idle
    case connecting
    case live
    /// The socket dropped and is being resumed in place; `attempt` counts from 1.
    case resuming(attempt: Int)
    /// Ended for a reason worth showing (server hang-up, giving up on resume).
    case closed(reason: String)
    /// Never got going: no key, audio device refused, and so on.
    case failed(reason: String)

    /// One short line for the notch and the menu.
    public var label: String {
        switch self {
        case .idle:                 return ""
        case .connecting:           return "connecting"
        case .live:                 return "live"
        case .resuming(let n):      return "resuming (\(n))"
        case .closed(let reason):   return "closed: \(reason)"
        case .failed(let reason):   return reason
        }
    }

    /// Whether the socket is up and carrying a conversation.
    public var isLive: Bool { self == .live }

    /// Whether this is a state the user should be able to see went wrong.
    public var isTrouble: Bool {
        switch self {
        case .resuming, .closed, .failed: return true
        case .idle, .connecting, .live:   return false
        }
    }
}

/// What Kweku can currently see, as its own axis from the connection.
public enum LiveVision: Equatable, Sendable {
    /// Streaming, but nothing aimed yet this session.
    case pending
    /// Streaming this window. `redacted` means the frame is being blanked
    /// before it leaves the machine.
    case watching(app: String, title: String, redacted: Bool)
    /// Blind: Screen Recording denied, or capture failed mid-session.
    case unavailable(reason: String)

    /// The line shown next to the eye. Kept short — this sits in a notch, and
    /// window titles are long.
    public var label: String {
        switch self {
        case .pending:                    return "looking…"
        case .unavailable:                return "can't see"
        case .watching(let app, _, true): return "\(app) · hidden"
        case .watching(let app, let title, false):
            return title.isEmpty ? app : "\(app) · \(title)"
        }
    }

    /// True when the frames leaving the machine are blanked.
    public var isRedacted: Bool {
        if case .watching(_, _, true) = self { return true }
        return false
    }

    public var isBlind: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// What Kweku is doing right now, in the one word the panel shows.
///
/// This is the state the old UI could only express as a rim colour, which is
/// unreadable if you aren't already looking at the notch — and indistinguishable
/// from the idle Live glow if you are.
public enum LiveActivity: Equatable, Sendable {
    case connecting
    case listening
    case thinking
    case speaking
    /// Mic off by the user's own hand.
    case muted
    /// Mic held by the half-duplex gate because Kweku is talking. Shown so the
    /// engine's deliberate deafness doesn't read as a dropped microphone.
    case held
    case ended

    public var label: String {
        switch self {
        case .connecting: return "connecting"
        case .listening:  return "listening"
        case .thinking:   return "thinking"
        case .speaking:   return "speaking"
        case .muted:      return "muted"
        case .held:       return "holding"
        case .ended:      return "ended"
        }
    }

    /// Resolve the one activity worth naming, most specific first.
    ///
    /// Mute outranks everything the session is doing: if the user has switched
    /// the microphone off, that is the fact that explains the silence, and no
    /// amount of "listening" underneath it is true.
    public static func resolve(phase: LivePhase, speaking: Bool, composing: Bool,
                               muted: Bool, gated: Bool) -> LiveActivity {
        switch phase {
        case .idle, .closed, .failed: return .ended
        case .connecting, .resuming:  return .connecting
        case .live:                   break
        }
        if muted { return .muted }
        if speaking { return .speaking }
        if composing { return .thinking }
        // The gate outlasts the audio by a short echo tail, so this only shows
        // in the beat right after Kweku stops — which is the beat where you'd
        // otherwise start talking and not be heard.
        if gated { return .held }
        return .listening
    }
}

/// Pure formatting for the Live panel.
public enum LiveFormat {
    /// Session clock: `0:07`, `4:31`, `1:02:09`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// Trim a window title to something a notch can hold without becoming a
    /// paragraph. Cuts on the tail, since the head of a title is the part that
    /// identifies it.
    public static func title(_ text: String, limit: Int = 34) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
