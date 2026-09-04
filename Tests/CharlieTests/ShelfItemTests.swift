import Foundation
import UniformTypeIdentifiers
import CharlieKit

enum ShelfItemTests {
    static func all() {
        Check.run("file keeps its name and content UTI for drag-out") {
            let item = ShelfItem(kind: .file, displayName: "Report.pdf",
                                 uti: UTType.pdf.identifier)
            Check.ok(item.suggestedFilename == "Report.pdf", "keeps filename")
            Check.ok(item.dragUTI == UTType.pdf.identifier, "advertises pdf uti")
        }

        Check.run("image maps to png/tiff extension and uti") {
            let png = ShelfItem(kind: .image, displayName: "image", uti: UTType.png.identifier)
            Check.ok(png.suggestedFilename.hasSuffix(".png"), "png ext")
            Check.ok(png.dragUTI == UTType.png.identifier, "png uti")
            let tiff = ShelfItem(kind: .image, displayName: "image", uti: UTType.tiff.identifier)
            Check.ok(tiff.suggestedFilename.hasSuffix(".tiff"), "tiff ext")
        }

        Check.run("text becomes .txt with plain-text uti") {
            let item = ShelfItem(kind: .text, displayName: "hello world", text: "hi")
            Check.ok(item.suggestedFilename.hasSuffix(".txt"), "txt ext")
            Check.ok(item.dragUTI == UTType.plainText.identifier, "plain-text uti")
        }

        Check.run("link becomes .webloc") {
            let item = ShelfItem(kind: .link, displayName: "example.com",
                                 urlString: "https://example.com")
            Check.ok(item.suggestedFilename.hasSuffix(".webloc"), "webloc ext")
            Check.ok(item.dragUTI == "com.apple.web-internet-location", "webloc uti")
        }

        Check.run("filenames are filesystem-sanitised") {
            let messy = ShelfItem(kind: .text, displayName: "a/b:c*d?e", text: "x")
            let name = messy.suggestedFilename
            Check.ok(!name.contains("/") && !name.contains(":"), "no path separators")
            Check.ok(name.hasSuffix(".txt"), "still .txt")
        }

        Check.run("empty name falls back per kind") {
            Check.ok(ShelfItem(kind: .text, displayName: "").suggestedFilename == "note.txt",
                     "text -> note")
            Check.ok(ShelfItem(kind: .link, displayName: "").suggestedFilename == "link.webloc",
                     "link -> link")
        }

        Check.run("persistence round-trips via Codable") {
            let original = ShelfItem(kind: .file, displayName: "a.txt",
                                     bookmark: Data([1, 2, 3]), uti: "public.plain-text")
            let data = try! JSONEncoder().encode([original])
            let back = try! JSONDecoder().decode([ShelfItem].self, from: data)
            Check.ok(back == [original], "decoded equals original")
        }
    }
}
