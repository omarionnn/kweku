import Foundation
import KwekuKit

enum MemoryTests {
    static func all() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kweku-mem-\(UUID().uuidString)/memory.json")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let t0 = Date(timeIntervalSince1970: 1000)

        Check.run("fragments coalesce into utterances") {
            var m = ConversationMemory(fileURL: tmp)
            m.append(role: "Kweku", fragment: "Hey", at: t0)
            m.append(role: "Kweku", fragment: "Omari,", at: t0 + 1)
            m.append(role: "Kweku", fragment: "build is green.", at: t0 + 2)
            Check.ok(m.lines.count == 1, "one line")
            Check.ok(m.lines[0].text == "Hey Omari, build is green.", "joined")
            m.append(role: "Omari", fragment: "nice", at: t0 + 3)
            Check.ok(m.lines.count == 2, "role switch starts a new line")
            m.append(role: "Omari", fragment: "one more", at: t0 + 30)
            Check.ok(m.lines.count == 3, "gap past window starts a new line")
        }

        Check.run("recap is bounded and ordered oldest-first") {
            var m = ConversationMemory(fileURL: tmp)
            for i in 0..<50 {
                m.append(role: "Omari", fragment: "message number \(i)", at: t0 + Double(i) * 100)
            }
            let recap = m.recap(maxChars: 300) ?? ""
            Check.ok(recap.contains("message number 49"), "newest included")
            Check.ok(!recap.contains("message number 1\n"), "oldest dropped by budget")
            let i48 = recap.range(of: "message number 48")!.lowerBound
            let i49 = recap.range(of: "message number 49")!.lowerBound
            Check.ok(i48 < i49, "oldest-first ordering")
            Check.ok(ConversationMemory(fileURL: tmp).recap() == nil || true, "no crash on fresh")
        }

        Check.run("caps total lines") {
            var m = ConversationMemory(fileURL: tmp)
            for i in 0..<400 {
                m.append(role: i % 2 == 0 ? "Omari" : "Kweku",
                         fragment: "line \(i)", at: t0 + Double(i) * 100)
            }
            Check.ok(m.lines.count == 300, "trimmed to max (got \(m.lines.count))")
            Check.ok(m.lines.last?.text == "line 399", "kept newest")
        }

        Check.run("persists and reloads") {
            var m = ConversationMemory(fileURL: tmp)
            m.append(role: "Omari", fragment: "remember the notch bug", at: t0)
            m.save()
            let reloaded = ConversationMemory(fileURL: tmp)
            Check.ok(reloaded.lines.count == 1 && reloaded.lines[0].text == "remember the notch bug",
                     "round-trip")
            var cleared = reloaded
            cleared.clear()
            Check.ok(ConversationMemory(fileURL: tmp).isEmpty, "clear wipes the file")
        }

        Check.run("setup carries resumption + recap; parser reads handles") {
            let frame = (try? JSONSerialization.jsonObject(
                with: GeminiLiveProtocol.setup(model: "m", system: "sys+recap", resumeHandle: "h123"))
                as? [String: Any]) ?? [:]
            let setup = frame["setup"] as? [String: Any]
            let resumption = setup?["sessionResumption"] as? [String: Any]
            Check.ok(resumption?["handle"] as? String == "h123", "handle passed")
            let fresh = (try? JSONSerialization.jsonObject(
                with: GeminiLiveProtocol.setup(model: "m")) as? [String: Any]) ?? [:]
            let freshRes = (fresh["setup"] as? [String: Any])?["sessionResumption"] as? [String: Any]
            Check.ok(freshRes != nil && freshRes?.isEmpty == true, "empty config when fresh")

            let update = #"{"sessionResumptionUpdate":{"newHandle":"abc","resumable":true}}"#
            Check.ok(GeminiLiveProtocol.parse(Data(update.utf8)) == [.resumptionHandle("abc")],
                     "handle event parsed")
            let notResumable = #"{"sessionResumptionUpdate":{"newHandle":"x","resumable":false}}"#
            Check.ok(GeminiLiveProtocol.parse(Data(notResumable.utf8)).isEmpty, "non-resumable ignored")
        }
    }
}
