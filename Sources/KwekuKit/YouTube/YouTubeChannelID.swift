import Foundation

/// Turning whatever you pasted into a channel id.
///
/// This is what replaced OAuth. Reading *your subscription list* is private
/// data and therefore needs a Google Cloud project, a consent screen, a
/// published app and a token that expires — a lot of apparatus for a list you
/// then throw almost all of away, since only the channels you pick ever open
/// the notch. Naming those channels directly skips every bit of it: a channel
/// id is public, its uploads are a public feed, and neither ever expires.
///
/// Everything you can copy from a browser is accepted — a channel URL, an
/// `@handle`, a legacy `/c/` or `/user/` vanity URL, a bare id, even a link to
/// one of the channel's videos, because that is often what you actually have
/// on the clipboard when you think "I want to follow this".
public enum YouTubeChannelID {

    /// Channel ids are 24 characters, always `UC`, then base64url-ish.
    public static func isChannelID(_ candidate: String) -> Bool {
        candidate.count == 24
            && candidate.hasPrefix("UC")
            && candidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// The id when it is already in the text, without a network round trip.
    ///
    /// A `/channel/` URL and a bare id are the two forms that carry the real
    /// id; everything else is a name that only YouTube can resolve.
    public static func direct(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isChannelID(trimmed) { return trimmed }
        guard let marker = trimmed.range(of: "/channel/") else { return nil }
        let id = String(trimmed[marker.upperBound...].prefix(24))
        return isChannelID(id) ? id : nil
    }

    /// Dig the id out of a fetched YouTube page.
    ///
    /// Three markers, most stable first. `channel_id=` comes from the RSS
    /// `<link rel="alternate">` that every channel page carries — it is the
    /// same URL this app polls, so if it is missing there is nothing to follow
    /// anyway. The two JSON keys are the player/metadata blobs, which move
    /// around between YouTube redesigns rather more than the feed link does.
    ///
    /// Scans past a marker that isn't followed by a valid id rather than
    /// giving up: these strings appear more than once per page, and an early
    /// truncated one shouldn't lose a good match further down.
    public static func inPage(_ html: String) -> String? {
        for marker in ["channel_id=", "\"externalId\":\"", "\"channelId\":\""] {
            var rest = Substring(html)
            while let found = rest.range(of: marker) {
                let candidate = String(rest[found.upperBound...].prefix(24))
                if isChannelID(candidate) { return candidate }
                rest = rest[found.upperBound...]
            }
        }
        return nil
    }

    /// The page to ask when the text is a name rather than an id.
    ///
    /// A bare word is treated as a handle, since that is what YouTube shows
    /// under every channel now and what someone is most likely to type.
    public static func pageURL(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("@") {
            return URL(string: "https://www.youtube.com/\(trimmed)")
        }
        return URL(string: "https://www.youtube.com/@\(trimmed)")
    }

    /// Resolve anything to a channel id, fetching only when it has to.
    public static func resolve(_ input: String) async -> String? {
        if let direct = direct(from: input) { return direct }
        guard let url = pageURL(for: input) else { return nil }

        var request = URLRequest(url: url)
        // Without a browser-ish agent YouTube serves a stripped page that
        // carries none of the three markers, and every paste looks invalid.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                         "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return inPage(html)
    }
}
