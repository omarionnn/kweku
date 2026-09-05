import Foundation
import KwekuKit

/// End-to-end drag-out materialisation: the half that's easy to forget. Uses a
/// real temp directory (the runner is an executable, not sandboxed XCTest).
enum PromisePayloadTests {
    static func all() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kweku-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        Check.run("text payload writes utf8 file") {
            let dest = tmp.appendingPathComponent("note.txt")
            try? PromisePayload.text("hello notch").write(to: dest)
            Check.ok((try? String(contentsOf: dest, encoding: .utf8)) == "hello notch",
                     "roundtrips text")
        }

        Check.run("image payload writes exact bytes") {
            let dest = tmp.appendingPathComponent("img.png")
            let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
            try? PromisePayload.image(bytes).write(to: dest)
            Check.ok((try? Data(contentsOf: dest)) == bytes, "roundtrips bytes")
        }

        Check.run("link payload writes a .webloc plist") {
            let dest = tmp.appendingPathComponent("link.webloc")
            try? PromisePayload.link("https://example.com").write(to: dest)
            let plist = (try? Data(contentsOf: dest)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
            } as? [String: Any]
            Check.ok(plist?["URL"] as? String == "https://example.com", "URL key present")
        }

        Check.run("file payload copies the original out (bookmark, not path)") {
            let src = tmp.appendingPathComponent("source.txt")
            try? "original".write(to: src, atomically: true, encoding: .utf8)
            let bookmark = try! src.bookmarkData()
            let dest = tmp.appendingPathComponent("copied.txt")
            try? PromisePayload.file(bookmark: bookmark).write(to: dest)
            Check.ok((try? String(contentsOf: dest, encoding: .utf8)) == "original",
                     "copy matches source")
            Check.ok(FileManager.default.fileExists(atPath: src.path),
                     "source untouched (copy, not move)")
        }

        Check.run("file payload overwrites an existing destination") {
            let src = tmp.appendingPathComponent("s2.txt")
            try? "v2".write(to: src, atomically: true, encoding: .utf8)
            let dest = tmp.appendingPathComponent("d2.txt")
            try? "stale".write(to: dest, atomically: true, encoding: .utf8)
            try? PromisePayload.file(bookmark: try! src.bookmarkData()).write(to: dest)
            Check.ok((try? String(contentsOf: dest, encoding: .utf8)) == "v2", "overwrote")
        }
    }
}
