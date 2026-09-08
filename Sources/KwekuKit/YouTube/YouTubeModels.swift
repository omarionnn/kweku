import Foundation

/// A channel the subscription sync found.
///
/// Every subscription is stored; only the *starred* ones are allowed to open
/// the notch. A sub list is a record of what you once clicked, sometimes years
/// ago — treating all of it as "interrupt me" would turn a two-second notice
/// into a full-time job. Starring is the line between "I follow this" and "tell
/// me the moment this lands".
public struct YouTubeChannel: Codable, Equatable, Identifiable, Sendable {
    /// The `UC…` channel id. Stable, and the only thing the Atom feed needs.
    public var id: String
    public var title: String
    public var avatarURL: URL?
    /// May this channel open the notch?
    public var starred: Bool

    public init(id: String, title: String, avatarURL: URL? = nil, starred: Bool = false) {
        self.id = id
        self.title = title
        self.avatarURL = avatarURL
        self.starred = starred
    }

    public var channelURL: URL? { URL(string: "https://www.youtube.com/channel/\(id)") }
}

/// One upload, as it appears in a channel's Atom feed.
public struct YouTubeUpload: Codable, Equatable, Identifiable, Sendable {
    /// The 11-character video id; also the dedupe key for "have I said this".
    public var id: String
    public var channelId: String
    public var channelTitle: String
    public var title: String
    public var published: Date
    /// The thumbnail the feed advertised. Usually `hqdefault`, which is 4:3
    /// with black bars baked in — see `thumbnailURL` for what we actually show.
    public var feedThumbnailURL: URL?

    public init(id: String, channelId: String, channelTitle: String, title: String,
                published: Date, feedThumbnailURL: URL? = nil) {
        self.id = id
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.title = title
        self.published = published
        self.feedThumbnailURL = feedThumbnailURL
    }

    public var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(id)") }

    /// The image to actually draw.
    ///
    /// The feed hands out `hqdefault.jpg` — 480×360, which is 4:3, so every
    /// modern 16:9 video arrives pillarboxed with black bars top and bottom.
    /// Drawn small in the notch those bars are most of the picture. `mqdefault`
    /// is true 16:9, always exists for every video (unlike `maxresdefault`),
    /// and at 320×180 is already larger than we draw it.
    public var thumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") ?? feedThumbnailURL
    }

    /// "2m ago", "3h ago" — the notch has room for about that much.
    public func age(now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(published))
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

/// Which uploads are worth opening the notch for.
///
/// Pure, because getting this wrong is the difference between a pleasant
/// notice and fifteen of them at once, and that is not something you want to
/// discover by watching the real notch.
public enum YouTubeUploadPolicy {
    /// Nothing older than this is ever announced.
    ///
    /// The feed carries the last ~15 uploads regardless of age, so without a
    /// window, starring a channel — or opening the laptop after a week away —
    /// would announce a backlog as if it had just landed. A drop says *this
    /// just happened*; anything that can't honestly claim that belongs in the
    /// panel, not over your work.
    public static let maxAge: TimeInterval = 12 * 3600

    /// Uploads to announce: from a starred channel, not already said, recent.
    ///
    /// Returned oldest-first so the queue says them in the order they landed.
    public static func announceable(_ uploads: [YouTubeUpload],
                                    seen: Set<String>,
                                    starred: Set<String>,
                                    now: Date = Date(),
                                    maxAge: TimeInterval = maxAge) -> [YouTubeUpload] {
        uploads
            .filter { starred.contains($0.channelId) }
            .filter { !seen.contains($0.id) }
            .filter { now.timeIntervalSince($0.published) <= maxAge }
            .sorted { $0.published < $1.published }
    }
}
