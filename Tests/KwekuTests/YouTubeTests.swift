import Foundation
import KwekuKit

enum YouTubeTests {

    /// A cut-down copy of a real feed, keeping every trap the parser has to
    /// survive: a channel-level `<title>` and a channel-level `<published>`
    /// (the date the channel was created, in 2008), a `<media:title>` nested
    /// inside the entry, and entries out of chronological order.
    static let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015"
          xmlns:media="http://search.yahoo.com/mrss/"
          xmlns="http://www.w3.org/2005/Atom">
     <id>yt:channel:XuqSBlHAE6Xw-yeJA0Tunw</id>
     <yt:channelId>UCXuqSBlHAE6Xw-yeJA0Tunw</yt:channelId>
     <title>Linus Tech Tips</title>
     <published>2008-11-25T00:46:52+00:00</published>
     <entry>
      <id>yt:video:aaaaaaaaaaa</id>
      <yt:videoId>aaaaaaaaaaa</yt:videoId>
      <yt:channelId>UCXuqSBlHAE6Xw-yeJA0Tunw</yt:channelId>
      <title>The older one</title>
      <author><name>Linus Tech Tips</name></author>
      <published>2026-09-07T12:00:00+00:00</published>
      <media:group>
       <media:title>The older one</media:title>
       <media:thumbnail url="https://i3.ytimg.com/vi/aaaaaaaaaaa/hqdefault.jpg" width="480" height="360"/>
      </media:group>
     </entry>
     <entry>
      <id>yt:video:bbbbbbbbbbb</id>
      <yt:videoId>bbbbbbbbbbb</yt:videoId>
      <yt:channelId>UCXuqSBlHAE6Xw-yeJA0Tunw</yt:channelId>
      <title>Why are people spending $1,000 for old iPods</title>
      <author><name>Linus Tech Tips</name></author>
      <published>2026-09-08T17:00:12+00:00</published>
      <media:group>
       <media:title>Why are people spending $1,000 for old iPods</media:title>
       <media:thumbnail url="https://i3.ytimg.com/vi/bbbbbbbbbbb/hqdefault.jpg" width="480" height="360"/>
      </media:group>
     </entry>
    </feed>
    """

    static func all() {
        Check.run("parses an Atom feed, newest first") {
            let uploads = YouTubeFeed.parse(Data(feed.utf8))
            Check.ok(uploads.count == 2, "two entries — got \(uploads.count)")
            guard uploads.count == 2 else { return }
            Check.ok(uploads[0].id == "bbbbbbbbbbb", "newest first")
            Check.ok(uploads[1].id == "aaaaaaaaaaa", "older second")
            Check.ok(uploads[0].title == "Why are people spending $1,000 for old iPods",
                     "entry title, not media:title or feed title")
            Check.ok(uploads[0].channelTitle == "Linus Tech Tips", "author name")
            Check.ok(uploads[0].channelId == "UCXuqSBlHAE6Xw-yeJA0Tunw", "channel id")
        }

        Check.run("entry published wins over the channel's creation date") {
            let uploads = YouTubeFeed.parse(Data(feed.utf8))
            guard let newest = uploads.first else { return Check.ok(false, "no entries") }
            // 2008 would mean the parser took the feed-level <published>.
            let year = Calendar(identifier: .gregorian)
                .component(.year, from: newest.published)
            Check.ok(year == 2026, "published from the entry — got \(year)")
        }

        Check.run("junk in, nothing out") {
            Check.ok(YouTubeFeed.parse(Data("not xml at all".utf8)).isEmpty, "garbage")
            Check.ok(YouTubeFeed.parse(Data()).isEmpty, "empty")
            Check.ok(YouTubeFeed.parse(Data("<feed><entry></entry></feed>".utf8)).isEmpty,
                     "entry with no video id is skipped")
        }

        Check.run("feed URL carries the channel id") {
            let url = YouTubeFeed.feedURL(channelId: "UC123")?.absoluteString ?? ""
            Check.ok(url.contains("channel_id=UC123"), "channel_id — got \(url)")
        }

        Check.run("thumbnail is the 16:9 one, not the feed's 4:3") {
            let upload = YouTubeUpload(
                id: "abc", channelId: "UC1", channelTitle: "c", title: "t",
                published: Date(),
                feedThumbnailURL: URL(string: "https://i3.ytimg.com/vi/abc/hqdefault.jpg"))
            let thumb = upload.thumbnailURL?.absoluteString ?? ""
            Check.ok(thumb.hasSuffix("/mqdefault.jpg"), "mqdefault — got \(thumb)")
            Check.ok(upload.watchURL?.absoluteString == "https://www.youtube.com/watch?v=abc",
                     "watch URL")
        }

        Check.run("age reads like a person wrote it") {
            let now = Date(timeIntervalSince1970: 1_000_000)
            func age(_ secondsAgo: TimeInterval) -> String {
                YouTubeUpload(id: "i", channelId: "c", channelTitle: "c", title: "t",
                              published: now - secondsAgo).age(now: now)
            }
            Check.ok(age(10) == "just now", "10s")
            Check.ok(age(300) == "5m ago", "5m")
            Check.ok(age(7200) == "2h ago", "2h")
            Check.ok(age(180_000) == "2d ago", "2d")
            Check.ok(age(-60) == "just now", "a clock skew into the future doesn't go negative")
        }

        Check.run("only unsilenced, unseen and recent uploads are announced") {
            let now = Date(timeIntervalSince1970: 2_000_000)
            func upload(_ id: String, _ channel: String, agoHours: Double) -> YouTubeUpload {
                YouTubeUpload(id: id, channelId: channel, channelTitle: channel,
                              title: id, published: now - agoHours * 3600)
            }
            let uploads = [
                upload("new", "UC-loud", agoHours: 1),
                upload("old", "UC-loud", agoHours: 40),      // outside the window
                upload("seen", "UC-loud", agoHours: 2),      // already said
                upload("other", "UC-quiet", agoHours: 1),    // silenced
            ]
            let out = YouTubeUploadPolicy.announceable(
                uploads, seen: ["seen"], notifying: ["UC-loud"], now: now)
            Check.ok(out.map(\.id) == ["new"], "only the new loud one — got \(out.map(\.id))")
        }

        Check.run("announcements come out oldest first") {
            let now = Date(timeIntervalSince1970: 2_000_000)
            let uploads = [
                YouTubeUpload(id: "b", channelId: "UC", channelTitle: "c", title: "b",
                              published: now - 600),
                YouTubeUpload(id: "a", channelId: "UC", channelTitle: "c", title: "a",
                              published: now - 3600),
            ]
            let out = YouTubeUploadPolicy.announceable(
                uploads, seen: [], notifying: ["UC"], now: now)
            Check.ok(out.map(\.id) == ["a", "b"], "said in the order they landed")
        }

        Check.run("a channel added by hand speaks unless silenced") {
            let channel = YouTubeChannel(id: "UC1", title: "Someone")
            Check.ok(channel.notifies, "you added it on purpose, so it may speak")
            Check.ok(channel.channelURL?.absoluteString
                        == "https://www.youtube.com/channel/UC1", "channel URL")
        }

        // MARK: - Resolving what was pasted

        Check.run("recognises a channel id") {
            Check.ok(YouTubeChannelID.isChannelID("UCXuqSBlHAE6Xw-yeJA0Tunw"), "real id")
            Check.ok(!YouTubeChannelID.isChannelID("UCtooshort"), "too short")
            Check.ok(!YouTubeChannelID.isChannelID("XXXuqSBlHAE6Xw-yeJA0Tunw"), "wrong prefix")
            Check.ok(!YouTubeChannelID.isChannelID("UCXuqSBlHAE6Xw yeJA0Tunw"), "space")
        }

        Check.run("pulls the id straight out when it's already there") {
            let id = "UCXuqSBlHAE6Xw-yeJA0Tunw"
            Check.ok(YouTubeChannelID.direct(from: id) == id, "bare id")
            Check.ok(YouTubeChannelID.direct(from: "  \(id)\n") == id, "whitespace trimmed")
            Check.ok(YouTubeChannelID.direct(
                from: "https://www.youtube.com/channel/\(id)") == id, "channel URL")
            Check.ok(YouTubeChannelID.direct(
                from: "https://www.youtube.com/channel/\(id)/videos") == id, "with a subpath")
            // A handle carries no id, so it must report that rather than
            // guessing — the caller's next step is a network fetch.
            Check.ok(YouTubeChannelID.direct(from: "https://www.youtube.com/@LinusTechTips") == nil,
                     "a handle is not an id")
            Check.ok(YouTubeChannelID.direct(from: "") == nil, "empty")
        }

        Check.run("digs the id out of a fetched page") {
            let id = "UCXuqSBlHAE6Xw-yeJA0Tunw"
            let rss = """
            <html><head><link rel="alternate" type="application/rss+xml"
            href="https://www.youtube.com/feeds/videos.xml?channel_id=\(id)"></head></html>
            """
            Check.ok(YouTubeChannelID.inPage(rss) == id, "from the RSS link")
            Check.ok(YouTubeChannelID.inPage(#"{"externalId":"\#(id)"}"#) == id, "from externalId")
            Check.ok(YouTubeChannelID.inPage(#"{"channelId":"\#(id)"}"#) == id, "from channelId")

            // A truncated marker early in the page must not lose a good match
            // further down; these strings appear many times per page.
            let messy = #"{"channelId":"UCtruncated"} … {"channelId":"\#(id)"}"#
            Check.ok(YouTubeChannelID.inPage(messy) == id, "scans past a bad match")
            Check.ok(YouTubeChannelID.inPage("<html>nothing here</html>") == nil, "no id")
        }

        Check.run("decides which page to ask for a name") {
            func page(_ input: String) -> String { YouTubeChannelID.pageURL(for: input)?.absoluteString ?? "" }
            Check.ok(page("@LinusTechTips") == "https://www.youtube.com/@LinusTechTips", "handle")
            Check.ok(page("LinusTechTips") == "https://www.youtube.com/@LinusTechTips",
                     "a bare word is treated as a handle")
            Check.ok(page("https://www.youtube.com/c/LinusTechTips")
                        == "https://www.youtube.com/c/LinusTechTips", "vanity URL passes through")
            Check.ok(page("https://www.youtube.com/watch?v=abc")
                        == "https://www.youtube.com/watch?v=abc", "a video link is fine too")
            Check.ok(YouTubeChannelID.pageURL(for: "   ") == nil, "blank")
        }
    }
}
