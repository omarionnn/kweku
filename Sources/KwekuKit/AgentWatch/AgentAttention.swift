import Foundation

/// Decides when a background agent session has waited long enough to be worth
/// interrupting a human for.
///
/// The agent panel already shows every session's state, but a panel only works
/// on someone who looks at it. Sessions that finish while attention is
/// elsewhere just sit there, and the cost of a stalled agent is measured in
/// however long it takes to glance at the notch again. Speaking is the only
/// channel that survives not being looked at.
///
/// Which makes restraint the whole design problem. An assistant that announces
/// every state change is one that gets muted, so: a session must have been
/// waiting a while, each session is announced at most once per stretch of
/// waiting, and going quiet again resets it.
public enum AgentAttention {

    /// One session judged worth mentioning.
    public struct Alert: Equatable {
        public var sessionID: String
        /// What to tell the model, in plain prose it can speak from.
        public var fact: String

        public init(sessionID: String, fact: String) {
            self.sessionID = sessionID
            self.fact = fact
        }
    }

    /// Per-session bookkeeping so the same wait isn't announced twice.
    public struct Ledger: Equatable {
        /// `stateSince` of the wait already announced for a session.
        var announced: [String: Date] = [:]

        public init() {}

        /// Forget sessions that no longer exist, so the ledger can't grow with
        /// every terminal window ever opened.
        mutating func retain(_ ids: Set<String>) {
            announced = announced.filter { ids.contains($0.key) }
        }
    }

    /// How long a session must sit in `waiting` before it is worth saying.
    /// Long enough that finishing a turn while the user is watching stays
    /// silent — they can already see it.
    public static let dwell: TimeInterval = 40

    /// Alerts to raise now, and the updated ledger.
    ///
    /// Only `waiting` counts: it is the state that means *the agent has
    /// stopped and cannot continue without you*. A working session is not a
    /// problem however long it runs.
    public static func alerts(sessions: [AgentSession],
                              ledger: Ledger,
                              now: Date,
                              dwell: TimeInterval = dwell,
                              limit: Int = 2) -> (alerts: [Alert], ledger: Ledger) {
        var ledger = ledger
        ledger.retain(Set(sessions.map(\.id)))

        // A session that went back to work has, by definition, been dealt
        // with — drop its record so its *next* wait can be announced.
        for session in sessions where session.state != .waiting {
            ledger.announced[session.id] = nil
        }

        let ripe = sessions
            .filter { $0.state == .waiting }
            .filter { now.timeIntervalSince($0.stateSince) >= dwell }
            // Same wait already mentioned: `stateSince` only moves when the
            // session changes state, so this is a stable identity for it.
            .filter { ledger.announced[$0.id] != $0.stateSince }
            .sorted { $0.stateSince < $1.stateSince }   // longest wait first

        let chosen = Array(ripe.prefix(limit))
        for session in chosen { ledger.announced[session.id] = session.stateSince }
        return (chosen.map { Alert(sessionID: $0.id, fact: fact(for: $0, now: now)) }, ledger)
    }

    /// The sentence's worth of truth handed to the model.
    static func fact(for session: AgentSession, now: Date) -> String {
        let waited = Int(now.timeIntervalSince(session.stateSince) / 60)
        let howLong = waited < 1 ? "under a minute" : "\(waited) minute\(waited == 1 ? "" : "s")"
        let place = session.cwd.isEmpty ? session.displayName
            : "\(session.displayName) (\(session.cwd))"
        return "The \(session.sourceLabel) session in \(place) has been waiting on Omari "
            + "for \(howLong) — it has stopped and needs him."
    }

    /// The full instruction sent into the Live conversation.
    public static func prompt(for alerts: [Alert]) -> String {
        let facts = alerts.map { "- \($0.fact)" }.joined(separator: "\n")
        return "System notice, not from Omari — one of his background agents needs "
            + "attention:\n\(facts)\n\nTell him in one short spoken sentence. Name the "
            + "project folder so he knows which one. Do not offer to fix it unless he asks."
    }
}
