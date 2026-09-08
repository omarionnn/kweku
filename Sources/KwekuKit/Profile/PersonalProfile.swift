import Foundation

/// The handful of facts every signup form asks for, held locally so Kweku can
/// answer them without being told.
///
/// Kweku has always known *about* Omari and never known anything *of* him: the
/// name in the persona is prose in a prompt, not data. So the one thing a
/// companion watching an empty form should be able to say — "I have four of
/// these five, want them in?" — was the one thing it could not.
///
/// **The values never leave the machine and never enter the model.** The system
/// instruction is told the field *names* only, which is enough to offer; the
/// model then asks for a field by name and `FieldFill` types the value straight
/// into the focused control. A profile in the prompt would ship his date of
/// birth to Google at the start of every session, form or no form.
public struct PersonalProfile: Equatable {

    /// Canonical key → value. Keys are the vocabulary the model is given.
    public private(set) var fields: [String: String]

    private let fileURL: URL

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kweku/profile.json")
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            fields = decoded.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        } else {
            fields = [:]
        }
    }

    // MARK: - Vocabulary

    /// Canonical key → the form labels that mean it.
    ///
    /// Forms label the same fact a dozen ways ("Full name", "Your name",
    /// "Legal name"), so matching is done on this table rather than on exact
    /// keys. Longest match wins, which is why `first name` can't be shadowed
    /// by `name`.
    public static let synonyms: [String: [String]] = [
        "full_name": ["full name", "your name", "legal name", "name"],
        "first_name": ["first name", "given name", "forename"],
        "last_name": ["last name", "surname", "family name"],
        "email": ["email", "e mail", "email address", "your email"],
        "phone": ["phone", "phone number", "mobile", "telephone", "cell"],
        "city": ["city", "town"],
        "location": ["where are you based", "based", "location", "city country",
                     "city state", "where are you located"],
        "country": ["country"],
        "date_of_birth": ["date of birth", "dob", "birthday", "birth date"],
        "github": ["github", "github url", "github profile"],
        "linkedin": ["linkedin", "linkedin url", "linkedin profile"],
        "website": ["website", "personal site", "portfolio", "url", "homepage"],
        "twitter": ["twitter", "x handle", "twitter handle"],
        "work_authorization": ["legally authorized to work in the us",
                               "work authorization", "authorized to work",
                               "visa status", "right to work"],
    ]

    /// Reduce a form label to comparable words: "LEGALLY AUTHORIZED TO WORK IN
    /// THE US? *" and "Legally authorized to work in the US" are the same
    /// question, and the asterisk marking it required is not part of it.
    public static func normalize(_ label: String) -> String {
        let scalars = label.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// The canonical key a form label is asking for, or nil if it isn't one we
    /// keep. Matching is longest-synonym-first so that a label containing
    /// "first name" never resolves to the shorter "name".
    public static func canonicalKey(for label: String) -> String? {
        let text = normalize(label)
        guard !text.isEmpty else { return nil }
        var best: (key: String, length: Int)?
        for (key, terms) in synonyms {
            for term in terms where text == term || text.contains(term) {
                if best == nil || term.count > best!.length {
                    best = (key, term.count)
                }
            }
        }
        return best?.key
    }

    // MARK: - Lookup

    /// The stored value for a form label or a canonical key. The model calls
    /// this with whatever the form said; both routes are accepted so it can
    /// pass "EMAIL *" or "email".
    public func value(for label: String) -> String? {
        if let direct = fields[label], !direct.isEmpty { return direct }
        guard let key = Self.canonicalKey(for: label) else { return nil }
        return fields[key]
    }

    /// Field names only — what the model is allowed to be told. Sorted so the
    /// system instruction is stable across launches.
    public var knownKeys: [String] { fields.keys.sorted() }

    public var isEmpty: Bool { fields.isEmpty }

    // MARK: - Editing

    public mutating func set(_ key: String, to value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { fields.removeValue(forKey: key) } else { fields[key] = trimmed }
    }

    public mutating func remove(_ key: String) { fields.removeValue(forKey: key) }

    public func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(fields) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Values worth typing into a form are worth not leaving world-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }
}
