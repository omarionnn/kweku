import Foundation

/// Kweku's long-term conversational memory: a rolling transcript of Live
/// sessions, persisted locally and injected as a recap into the next
/// session's system instruction ("Kweku remembers").
///
/// Privacy note (deliberate): this is the one place conversations touch disk,
/// in plaintext under Application Support. "Forget Conversations" in the menu
/// wipes it.
public struct ConversationMemory: Equatable {
    public struct Line: Codable, Equatable {
        public var role: String       // "Omari" | "Kweku"
        public var text: String
        public var at: Date
    }

    public private(set) var lines: [Line] = []
    private let fileURL: URL

    /// Fragments within this window coalesce onto the previous same-role line
    /// (Live transcripts stream word-by-word).
    public static let coalesceWindow: TimeInterval = 6
    public static let maxLines = 300
    public static let recapMaxChars = 2500

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kweku/conversation-memory.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([Line].self, from: data) {
            lines = decoded
        }
    }

    // MARK: - Recording

    public mutating func append(role: String, fragment: String, at now: Date = Date()) {
        let text = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if var last = lines.last, last.role == role,
           now.timeIntervalSince(last.at) < Self.coalesceWindow {
            last.text += last.text.hasSuffix(" ") || text.first == " " ? fragment : " " + text
            last.at = now
            lines[lines.count - 1] = last
        } else {
            lines.append(Line(role: role, text: text, at: now))
        }
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }

    public mutating func clear() {
        lines.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(lines) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Recap

    public var isEmpty: Bool { lines.isEmpty }

    /// The tail of the transcript, bounded, ready to append to the system
    /// instruction.
    public func recap(maxChars: Int = recapMaxChars) -> String? {
        guard !lines.isEmpty else { return nil }
        var chunks: [String] = []
        var total = 0
        for line in lines.reversed() {
            let rendered = "\(line.role): \(line.text)"
            total += rendered.count + 1
            if total > maxChars { break }
            chunks.append(rendered)
        }
        guard !chunks.isEmpty else { return nil }
        return """


        Memory of your previous conversations with Omari (oldest first; use it \
        for continuity, don't recite it):
        \(chunks.reversed().joined(separator: "\n"))
        """
    }
}
