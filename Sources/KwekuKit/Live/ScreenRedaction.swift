import Foundation

/// Decides whether the window Kweku is aimed at is allowed to leave the machine.
///
/// The vision channel ships the focused window to Google once a second, for as
/// long as a Live session is open. That is fine for an editor and indefensible
/// for a password vault, and the user cannot be expected to remember which one
/// is in front before they start talking. So the capture path asks here first,
/// and a denied window is replaced by a placeholder card rather than skipped —
/// silence would just look like the starvation bug all over again.
///
/// Deliberately biased towards over-redaction. A wrongly hidden window costs
/// one sentence of "I can't see that one"; a wrongly shared one cannot be taken
/// back, because it is already in someone else's logs.
public enum ScreenRedaction {

    /// The window under consideration, as the window server describes it.
    public struct Window: Equatable {
        public var app: String
        public var title: String

        public init(app: String, title: String) {
            self.app = app
            self.title = title
        }
    }

    public enum Verdict: Equatable {
        case allow
        /// Hidden, with a short human reason for the status line.
        case redact(String)

        public var isRedacted: Bool {
            if case .redact = self { return true }
            return false
        }

        public var reason: String? {
            if case .redact(let r) = self { return r }
            return nil
        }
    }

    /// Apps where every window is secret by construction, so the title never
    /// needs consulting.
    public static let deniedApps = [
        "1password", "bitwarden", "dashlane", "lastpass", "keepassxc",
        "keychain access", "passwords", "proton pass", "enpass", "authy",
        "secretive", "strongbox", "nordpass", "roboform",
    ]

    /// Fragments that mark a window sensitive whichever app it belongs to — a
    /// browser tab, an editor buffer, a terminal running `cat` on the wrong
    /// file. Matched case-insensitively anywhere in the title.
    public static let deniedTitleFragments = [
        ".env", "id_rsa", "id_ed25519", ".pem", ".p12", "keychain",
        "credential", "secret", "private key", "api key", "access token",
        "password", "passphrase", "seed phrase", "recovery code",
        "one-time code", "authenticator", "2fa",
        "private browsing", "incognito",
    ]

    /// User-supplied extra terms, so a redaction can be added without a build.
    /// `defaults write com.kweku.app redactionTerms -array "acme-payroll" …`
    public static var userTerms: [String] {
        (UserDefaults.standard.array(forKey: "redactionTerms") as? [String]) ?? []
    }

    /// Whether redaction is on at all. On by default: the safe setting has to
    /// be the one you get by not knowing the feature exists.
    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: "redactionEnabled") as? Bool ?? true
    }

    public static func verdict(for window: Window,
                              extraTerms: [String] = [],
                              enabled: Bool = true) -> Verdict {
        guard enabled else { return .allow }
        let app = window.app.lowercased()
        let title = window.title.lowercased()

        if deniedApps.contains(where: { app.contains($0) }) {
            return .redact("\(window.app) is never shared")
        }
        for term in deniedTitleFragments where title.contains(term) {
            return .redact("window title mentions “\(term)”")
        }
        for term in extraTerms.map({ $0.lowercased() }) where !term.isEmpty {
            if title.contains(term) || app.contains(term) {
                return .redact("matches your redaction term “\(term)”")
            }
        }
        return .allow
    }
}
