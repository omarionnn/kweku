import Foundation
import KwekuKit

enum FormWatchTests {

    /// The a16z Speedrun form that started all of this: five questions, three of
    /// them things Kweku holds, one an essay it can't help with.
    static let speedrun = [
        FormScan.Field(label: "FULL NAME *", isEmpty: true),
        FormScan.Field(label: "EMAIL *", isEmpty: true),
        FormScan.Field(label: "WHERE ARE YOU BASED? *", isEmpty: true),
        FormScan.Field(label: "Why do you want to join?", isEmpty: true),
    ]
    static let holding: Set<String> = ["email", "full_name", "location", "phone"]

    static func all() {
        Check.run("a form is read down to the fields Kweku can actually answer") {
            let form = FormScan.read(app: "Chrome", fields: speedrun, holding: holding)
            Check.ok(form.offerable == ["email", "full_name", "location"], "three offerable, sorted")
            Check.ok(form.emptyCount == 4, "the essay still counts as an empty field")
            Check.ok(!form.offerable.contains("phone"), "held but not asked for stays unmentioned")
        }

        Check.run("a field already filled in is not offered") {
            let fields = [
                FormScan.Field(label: "EMAIL *", isEmpty: false),
                FormScan.Field(label: "FULL NAME *", isEmpty: true),
            ]
            let form = FormScan.read(app: "Chrome", fields: fields, holding: holding)
            Check.ok(form.offerable == ["full_name"], "only the empty one")
            Check.ok(form.emptyCount == 1, "empties counted, not fields")
        }

        Check.run("a field we don't hold is not offered") {
            let fields = [FormScan.Field(label: "DATE OF BIRTH *", isEmpty: true)]
            let form = FormScan.read(app: "Chrome", fields: fields, holding: holding)
            Check.ok(form.offerable.isEmpty, "recognised, but nothing on file for it")
        }

        Check.run("filling the form in does not make it a new form") {
            // The bug this prevents: signing by what is still empty means every
            // keystroke he types earns a fresh offer for the same page.
            let untouched = FormScan.read(app: "Chrome", fields: speedrun, holding: holding)
            let halfDone = FormScan.read(app: "Chrome", fields: [
                FormScan.Field(label: "FULL NAME *", isEmpty: false),
                FormScan.Field(label: "EMAIL *", isEmpty: false),
                FormScan.Field(label: "WHERE ARE YOU BASED? *", isEmpty: true),
                FormScan.Field(label: "Why do you want to join?", isEmpty: true),
            ], holding: holding)
            Check.ok(untouched.signature == halfDone.signature, "same form while being filled")

            let elsewhere = FormScan.read(app: "Safari", fields: speedrun, holding: holding)
            Check.ok(untouched.signature != elsewhere.signature, "another app is another form")

            let checkout = FormScan.read(app: "Chrome", fields: [
                FormScan.Field(label: "Phone number", isEmpty: true),
                FormScan.Field(label: "Email", isEmpty: true),
            ], holding: holding)
            Check.ok(untouched.signature != checkout.signature, "different questions, different form")
        }

        // MARK: - When it is worth saying something

        let now = Date()

        Check.run("a real form is worth interrupting for") {
            let form = FormScan.read(app: "Chrome", fields: speedrun, holding: holding)
            let (fire, next) = FormWatch.evaluate(
                form: form, state: FormWatch.State(), now: now, sessionLive: true, busy: false)
            Check.ok(fire, "three fields he'd otherwise retype")
            Check.ok(next != FormWatch.State(), "firing moved the state on")
        }

        Check.run("a lone box on a page is not a form") {
            // A newsletter signup, a footer, a search bar called "Email".
            let stray = FormScan.read(app: "Safari", fields: [
                FormScan.Field(label: "Email", isEmpty: true),
            ], holding: holding)
            let (fire, _) = FormWatch.evaluate(
                form: stray, state: FormWatch.State(), now: now, sessionLive: true, busy: false)
            Check.ok(!fire, "one field alone stays quiet")

            // ...but one known field among several empty ones is an application
            // with one question we happen to be able to answer.
            let application = FormScan.read(app: "Safari", fields: [
                FormScan.Field(label: "Email", isEmpty: true),
                FormScan.Field(label: "Why this role?", isEmpty: true),
                FormScan.Field(label: "Notice period", isEmpty: true),
            ], holding: holding)
            let (fires, _) = FormWatch.evaluate(
                form: application, state: FormWatch.State(), now: now, sessionLive: true, busy: false)
            Check.ok(fires, "one known field among many empties is still worth it")
        }

        Check.run("nothing to offer is nothing to say") {
            let form = FormScan.read(app: "Chrome", fields: speedrun, holding: [])
            let (fire, _) = FormWatch.evaluate(
                form: form, state: FormWatch.State(), now: now, sessionLive: true, busy: false)
            Check.ok(!fire, "empty profile never speaks")
        }

        Check.run("the same form is offered once and then let go") {
            let form = FormScan.read(app: "Chrome", fields: speedrun, holding: holding)
            let (first, state) = FormWatch.evaluate(
                form: form, state: FormWatch.State(), now: now, sessionLive: true, busy: false)
            Check.ok(first, "offered")
            let (again, _) = FormWatch.evaluate(
                form: form, state: state, now: now.addingTimeInterval(600),
                sessionLive: true, busy: false)
            Check.ok(!again, "not a second time, however long he sits there")
        }

        Check.run("a different form still waits out the cooldown") {
            let first = FormScan.read(app: "Chrome", fields: speedrun, holding: holding)
            let (_, state) = FormWatch.evaluate(
                form: first, state: FormWatch.State(), now: now, sessionLive: true, busy: false)
            let second = FormScan.read(app: "Safari", fields: speedrun, holding: holding)

            let (tooSoon, _) = FormWatch.evaluate(
                form: second, state: state, now: now.addingTimeInterval(30),
                sessionLive: true, busy: false)
            Check.ok(!tooSoon, "two offers half a minute apart is pestering")

            let (later, _) = FormWatch.evaluate(
                form: second, state: state, now: now.addingTimeInterval(FormWatch.cooldown + 1),
                sessionLive: true, busy: false)
            Check.ok(later, "past the cooldown a genuinely new form is fair game")
        }

        Check.run("never over the top of Kweku's own sentence") {
            let form = FormScan.read(app: "Chrome", fields: speedrun, holding: holding)
            let (speaking, unchanged) = FormWatch.evaluate(
                form: form, state: FormWatch.State(), now: now, sessionLive: true, busy: true)
            Check.ok(!speaking, "busy means silent")
            Check.ok(unchanged == FormWatch.State(), "and a refused offer burns no cooldown")

            let (dead, _) = FormWatch.evaluate(
                form: form, state: FormWatch.State(), now: now, sessionLive: false, busy: false)
            Check.ok(!dead, "no session, no offer")
        }

        // MARK: - What it says

        Check.run("the offer names fields, never values, and never submits") {
            let form = FormScan.read(app: "Chrome", fields: speedrun, holding: holding)
            let prompt = FormWatch.prompt(form: form)
            Check.ok(prompt.contains("full name") && prompt.contains("email"), "names what it has")
            Check.ok(prompt.contains("Chrome"), "says where")
            Check.ok(prompt.contains("did not say anything"), "marked as unprompted")
            Check.ok(prompt.contains("not come from your video feed"),
                     "told where this came from, so it can't claim to have seen it")
            Check.ok(prompt.contains("wait for his answer"), "offer, then stop")
            Check.ok(prompt.contains("until he agrees"), "no filling before consent")
            Check.ok(prompt.contains("Never submit"), "the last click stays his")
            Check.ok(prompt.contains("do not raise"), "one offer per form")
        }
    }
}
