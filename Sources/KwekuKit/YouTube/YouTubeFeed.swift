import Foundation

/// A channel's uploads, read from the public Atom feed.
///
/// This is deliberately *not* the Data API. `playlistItems.list` would cost
/// quota on every poll of every channel, and polling is the whole job — a
/// dozen starred channels every five minutes is thousands of calls a day
/// against a 10,000-unit budget. The Atom feed at
/// `youtube.com/feeds/videos.xml` is unauthenticated, uncounted, and carries
/// everything a notice needs: id, title, channel, timestamp, thumbnail. The
/// API is used once a day for the *subscription list*, which the feed can't
/// give us; uploads come from here.
public enum YouTubeFeed {

    public static func feedURL(channelId: String) -> URL? {
        var c = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")
        c?.queryItems = [.init(name: "channel_id", value: channelId)]
        return c?.url
    }

    /// Parse an Atom feed into uploads, newest first.
    ///
    /// Returns an empty array rather than throwing: a malformed or truncated
    /// feed is a transient network fact, and a poll that finds nothing is the
    /// correct outcome for it — there is nothing the notch could usefully say.
    public static func parse(_ data: Data) -> [YouTubeUpload] {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Left off on purpose: with namespace processing disabled, element
        // names arrive exactly as written in the document (`yt:videoId`,
        // `media:thumbnail`), which is what the path matching below expects.
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return [] }
        return delegate.uploads.sorted { $0.published > $1.published }
    }
}

/// Path-matching Atom reader.
///
/// Matching on element *paths* rather than bare names is not fussiness: the
/// feed has a `<title>` for the channel and a `<title>` per entry and a third
/// `<media:title>` inside each entry's `media:group`, and `<published>` appears
/// both per-entry and once at feed level holding the date the channel was
/// created in 2008. Matching on the name alone silently picks the wrong one.
private final class FeedDelegate: NSObject, XMLParserDelegate {
    var uploads: [YouTubeUpload] = []

    private var path: [String] = []
    private var text = ""

    /// Channel title from the feed header, used when an entry omits its author.
    private var feedTitle = ""
    private var feedChannelId = ""

    private var videoId = ""
    private var channelId = ""
    private var channelTitle = ""
    private var title = ""
    private var published: Date?
    private var thumbnail: URL?

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var inEntry: Bool { path.first(where: { $0 == "entry" }) != nil }

    /// Does the current path end with this sequence?
    private func at(_ tail: String...) -> Bool {
        guard path.count >= tail.count else { return false }
        return Array(path.suffix(tail.count)) == tail
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        path.append(elementName)
        text = ""

        if elementName == "entry" { resetEntry() }

        if inEntry, at("media:group", "media:thumbnail"),
           let url = attributeDict["url"] {
            thumbnail = URL(string: url)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if inEntry {
            if at("entry", "yt:videoId") { videoId = value }
            else if at("entry", "yt:channelId") { channelId = value }
            else if at("entry", "title") { title = value }
            else if at("entry", "published") { published = Self.iso.date(from: value) }
            else if at("entry", "author", "name") { channelTitle = value }
            else if elementName == "entry" { commit() }
        } else {
            if at("feed", "title") { feedTitle = value }
            else if at("feed", "yt:channelId") { feedChannelId = value }
        }

        path.removeLast()
        text = ""
    }

    private func resetEntry() {
        videoId = ""; channelId = ""; channelTitle = ""; title = ""
        published = nil; thumbnail = nil
    }

    private func commit() {
        guard !videoId.isEmpty, let published else { return }
        uploads.append(YouTubeUpload(
            id: videoId,
            channelId: channelId.isEmpty ? feedChannelId : channelId,
            channelTitle: channelTitle.isEmpty ? feedTitle : channelTitle,
            title: title,
            published: published,
            feedThumbnailURL: thumbnail))
        resetEntry()
    }
}
