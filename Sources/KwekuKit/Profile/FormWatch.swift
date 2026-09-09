import Foundation

/// Decides whether a form on screen is worth speaking up about.
///
/// `FormScan` answers "is there a form and what do I have for it". That is the
/// easy half. The hard half is the same one `TriageTrigger` has: an assistant
/// that offers to fill in every text box on the internet is worse than one that
/// waits to be asked, and it only takes a handful of bad interruptions before
/// the feature gets switched off for good. So finding a match is necessary and
/// nowhere near sufficient.
///
/// Four gates, each earning its place:
/// - **Worth the interruption.** Two known fields is a form. One is usually a
///   newsletter box or a search bar that happens to be called something we
///   recognise — unless it sits among several other empty fields, which makes
///   it an application with one question we can answer and four we can't.
/// - **Once per form.** Signed by what is on the form, not by what is still
///   empty, so filling it in doesn't make it new again.
/// - **Cooldown.** A floor under how often an unasked-for sentence can happen
///   at all, whatever he's browsing.
/// - **Not mid-sentence.** `clientContent` completes a turn, so offering while
///   Kweku is already talking cuts it off in its own words.
public enum FormWatch {

    public struct State: Equatable {
        var lastFiredAt = Date.distantPast
        var lastSignature = ""

        public init() {}
    }

    /// Minimum gap between two unsolicited offers. Shorter than triage's four
    /// minutes: filling in forms comes in bursts, and the second page of a
    /// signup is a genuinely new chance to help, not a nag.
    public static let cooldown: TimeInterval = 120

    /// Off switch, for when the offer is not wanted at all:
    /// `defaults write com.omari.Kweku watchForms -bool false`.
    /// Unprompted speech should always have one of these.
    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: "watchForms") as? Bool ?? true
    }

    /// Whether to offer on this form, and the updated state.
    public static func evaluate(form: FormScan.Form,
                                state: State,
                                now: Date,
                                sessionLive: Bool,
                                busy: Bool,
                                cooldown: TimeInterval = cooldown) -> (fire: Bool, state: State) {
        guard sessionLive, !busy else { return (false, state) }
        guard worthInterrupting(form) else { return (false, state) }
        guard form.signature != state.lastSignature else { return (false, state) }
        guard now.timeIntervalSince(state.lastFiredAt) >= cooldown else { return (false, state) }

        var next = state
        next.lastFiredAt = now
        next.lastSignature = form.signature
        return (true, next)
    }

    /// Two known fields, or one known field on something that is clearly a form
    /// rather than a stray box.
    static func worthInterrupting(_ form: FormScan.Form) -> Bool {
        if form.offerable.count >= 2 { return true }
        return form.offerable.count == 1 && form.emptyCount >= 3
    }

    /// The notice sent into the Live conversation.
    ///
    /// It states the finding rather than asking the model to look, because on
    /// an injected turn it cannot look — that is measured, not assumed. Field
    /// names only, which is all this side of the app has anyway.
    ///
    /// The instruction to stop after offering matters as much as the offer.
    /// Filling four fields because he grunted is how a helpful feature becomes
    /// one you have to undo, and the last click on a submitted application is
    /// his by right.
    public static func prompt(form: FormScan.Form) -> String {
        let list = form.offerable
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: ", ")
        return "System notice, not from Omari — he did not say anything, and this did not "
            + "come from your video feed. A form is open in front of him in \(form.app). "
            + "These fields on it are empty, and they are ones you hold for him: \(list).\n\n"
            + "Say so now, in one short spoken sentence: name what you have and offer to "
            + "type it in. Then stop and wait for his answer. Do not call `fill_field` "
            + "until he agrees, one call per field once he does. Do not say any of the "
            + "values — you do not have them, only the names. Never submit the form or "
            + "press any button. If he says no or ignores it, drop it and do not raise "
            + "this form again."
    }
}
