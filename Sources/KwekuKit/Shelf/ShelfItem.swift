import Foundation
import UniformTypeIdentifiers

/// The four things the notch can hold.
public enum ShelfKind: String, Codable, Sendable {
    case file, link, text, image
}

/// A single held item. File items keep a *security-scoped bookmark* (never a
/// path, never a copy). Image bytes live in a blob file; text/links inline.
public struct ShelfItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: ShelfKind
    public var addedAt: Date
    public var displayName: String

    public var bookmark: Data?    // .file
    public var urlString: String? // .link
    public var text: String?      // .text
    public var blobFile: String?  // .image  (filename within blobs/)
    public var uti: String?       // .file / .image content type identifier

    public init(id: UUID = UUID(), kind: ShelfKind, addedAt: Date = Date(),
                displayName: String, bookmark: Data? = nil, urlString: String? = nil,
                text: String? = nil, blobFile: String? = nil, uti: String? = nil) {
        self.id = id; self.kind = kind; self.addedAt = addedAt
        self.displayName = displayName; self.bookmark = bookmark
        self.urlString = urlString; self.text = text
        self.blobFile = blobFile; self.uti = uti
    }

    // MARK: - Pure presentation logic (unit-tested)

    /// UTI advertised to the file-promise drag so receivers know the type.
    public var dragUTI: String {
        switch kind {
        case .file:  return uti ?? UTType.data.identifier
        case .image: return uti ?? UTType.png.identifier
        case .text:  return UTType.plainText.identifier
        case .link:  return "com.apple.web-internet-location"
        }
    }

    /// Filename offered to Finder/Mail/Slack when the item is dragged out.
    public var suggestedFilename: String {
        switch kind {
        case .file:
            return displayName.isEmpty ? "item" : displayName
        case .image:
            let ext = (uti == UTType.tiff.identifier) ? "tiff" : "png"
            return "\(Self.sanitize(displayName, fallback: "image")).\(ext)"
        case .text:
            return "\(Self.sanitize(displayName, fallback: "note")).txt"
        case .link:
            return "\(Self.sanitize(displayName, fallback: "link")).webloc"
        }
    }

    /// Filesystem-safe base name; collapses anything non-alphanumeric.
    static func sanitize(_ raw: String, fallback: String) -> String {
        let mapped = raw.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        let trimmed = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(40))
    }
}
