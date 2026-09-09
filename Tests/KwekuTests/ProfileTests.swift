import Foundation
import KwekuKit

enum ProfileTests {
    static func all() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kweku-profile-\(UUID().uuidString)/profile.json")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        Check.run("form labels resolve to canonical fields") {
            // The real labels off the a16z Speedrun form that started this.
            Check.ok(PersonalProfile.canonicalKey(for: "EMAIL *") == "email", "email, decorated")
            Check.ok(PersonalProfile.canonicalKey(for: "FULL NAME *") == "full_name", "full name")
            Check.ok(PersonalProfile.canonicalKey(for: "WHERE ARE YOU BASED? *") == "location",
                     "based -> location")
            Check.ok(PersonalProfile.canonicalKey(for: "DATE OF BIRTH *") == "date_of_birth", "dob")
            Check.ok(PersonalProfile.canonicalKey(
                for: "LEGALLY AUTHORIZED TO WORK IN THE US? *") == "work_authorization",
                     "work authorization")
        }

        Check.run("longest synonym wins over a shorter substring") {
            // "first name" contains "name"; resolving it to full_name would put
            // his whole name in the first-name box.
            Check.ok(PersonalProfile.canonicalKey(for: "First name") == "first_name", "first name")
            Check.ok(PersonalProfile.canonicalKey(for: "Last name") == "last_name", "last name")
            Check.ok(PersonalProfile.canonicalKey(for: "Name") == "full_name", "bare name")
        }

        Check.run("unknown labels resolve to nothing rather than something") {
            Check.ok(PersonalProfile.canonicalKey(for: "Why do you want to join?") == nil,
                     "essay question is not a field")
            Check.ok(PersonalProfile.canonicalKey(for: "") == nil, "empty label")
            Check.ok(PersonalProfile.canonicalKey(for: "*") == nil, "punctuation only")
        }

        Check.run("lookup goes by label or by key, and round-trips to disk") {
            var p = PersonalProfile(fileURL: tmp)
            p.set("email", to: "someone@example.com")
            p.set("full_name", to: "A Name")
            p.set("location", to: "New York, NY")
            p.save()

            let reloaded = PersonalProfile(fileURL: tmp)
            Check.ok(reloaded.value(for: "EMAIL *") == "someone@example.com", "by form label")
            Check.ok(reloaded.value(for: "email") == "someone@example.com", "by canonical key")
            Check.ok(reloaded.value(for: "WHERE ARE YOU BASED? *") == "New York, NY", "by synonym")
            Check.ok(reloaded.value(for: "phone") == nil, "absent field is nil, not empty string")
            Check.ok(reloaded.knownKeys == ["email", "full_name", "location"], "keys sorted")
        }

        Check.run("blank values are dropped, not stored") {
            var p = PersonalProfile(fileURL: tmp)
            p.set("phone", to: "   ")
            Check.ok(p.value(for: "phone") == nil, "whitespace is not a value")
            p.set("phone", to: " 555 ")
            Check.ok(p.value(for: "phone") == "555", "trimmed on the way in")
            p.remove("phone")
            Check.ok(p.value(for: "phone") == nil, "removed")
        }

        Check.run("the model is told field names and never values") {
            var p = PersonalProfile(fileURL: tmp)
            p.set("email", to: "secret@example.com")
            p.set("date_of_birth", to: "1999-01-01")
            let note = GeminiLiveProtocol.profileNote(fields: p.knownKeys, sighted: true)
            Check.ok(note.contains("email"), "names the field")
            Check.ok(!note.contains("secret@example.com"), "never the address")
            Check.ok(!note.contains("1999-01-01"), "never the birth date")
            Check.ok(note.contains("offer"), "told to offer unprompted")
            Check.ok(note.contains("never submit"), "told not to submit")
        }

        Check.run("nothing on file means nothing in the prompt") {
            Check.ok(GeminiLiveProtocol.profileNote(fields: [], sighted: true).isEmpty,
                     "empty profile adds no instruction")
            let blind = GeminiLiveProtocol.profileNote(fields: ["email"], sighted: false)
            Check.ok(blind.contains("fill_field"), "blind still knows it can type on request")
            Check.ok(!blind.contains("When you can see"), "but is not told to watch for forms")
        }

        Check.run("system instruction carries the profile without leaking it") {
            let system = GeminiLiveProtocol.systemInstruction(
                visionAvailable: true, profileFields: ["email", "full_name"])
            Check.ok(system.contains("email, full_name"), "fields listed")
            Check.ok(system.contains("You can also see"), "vision section intact")
        }

        Check.run("refusals are sentences Kweku can say") {
            Check.ok(FieldFill.Refusal.noFocusedField.spoken.contains("click into the field"),
                     "tells him what to do")
            Check.ok(FieldFill.Refusal.unknownField("phone").spoken.contains("phone"),
                     "names the missing field")
            Check.ok(FieldFill.Refusal.notEditable(role: "AXButton").spoken.contains("AXButton"),
                     "names what was focused instead")
            Check.ok(FieldFill.Refusal.noAccessibility.spoken.contains("Accessibility"),
                     "names the permission")
        }
    }
}
