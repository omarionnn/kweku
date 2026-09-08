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

        Check.run("only starred, unseen and recent uploads are announced") {
            let now = Date(timeIntervalSince1970: 2_000_000)
            func upload(_ id: String, _ channel: String, agoHours: Double) -> YouTubeUpload {
                YouTubeUpload(id: id, channelId: channel, channelTitle: channel,
                              title: id, published: now - agoHours * 3600)
            }
            let uploads = [
                upload("new", "UC-star", agoHours: 1),
                upload("old", "UC-star", agoHours: 40),      // outside the window
                upload("seen", "UC-star", agoHours: 2),      // already said
                upload("other", "UC-plain", agoHours: 1),    // not starred
            ]
            let out = YouTubeUploadPolicy.announceable(
                uploads, seen: ["seen"], starred: ["UC-star"], now: now)
            Check.ok(out.map(\.id) == ["new"], "only the new starred one — got \(out.map(\.id))")
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
                uploads, seen: [], starred: ["UC"], now: now)
            Check.ok(out.map(\.id) == ["a", "b"], "said in the order they landed")
        }

        Check.run("subscriptions decode from resourceId, not the subscription id") {
            let json = """
            {"nextPageToken":"CDIQAA","items":[
              {"id":"SUBSCRIPTION-ID-NOT-CHANNEL",
               "snippet":{"title":"Veritasium",
                          "resourceId":{"channelId":"UCHnyfMqiRRG1u-2MsSQLbXA"},
                          "thumbnails":{"default":{"url":"https://yt3.ggpht.com/x=s88"}}}},
              {"id":"another","snippet":{"title":"No resource id here"}}
            ]}
            """
            guard let out = YouTubeAPI.decodeSubscriptions(Data(json.utf8)) else {
                return Check.ok(false, "failed to decode")
            }
            Check.ok(out.channels.count == 1, "the malformed item is skipped")
            Check.ok(out.channels.first?.id == "UCHnyfMqiRRG1u-2MsSQLbXA", "channel id")
            Check.ok(out.channels.first?.title == "Veritasium", "title")
            Check.ok(out.channels.first?.avatarURL != nil, "avatar")
            Check.ok(out.channels.first?.starred == false, "nothing arrives starred")
            Check.ok(out.nextPage == "CDIQAA", "page cursor")
            Check.ok(YouTubeAPI.decodeSubscriptions(Data("{}".utf8)) == nil, "no items = nil")
        }

        Check.run("subscriptions URL asks for mine, with a page cursor") {
            let first = YouTubeAPI.subscriptionsURL().absoluteString
            Check.ok(first.contains("mine=true"), "mine")
            Check.ok(first.contains("part=snippet"), "part")
            Check.ok(!first.contains("pageToken"), "no cursor on the first page")
            Check.ok(YouTubeAPI.subscriptionsURL(pageToken: "CDIQAA")
                .absoluteString.contains("pageToken=CDIQAA"), "cursor")
        }

        Check.run("token responses, including a refresh that omits the refresh token") {
            let full = #"{"access_token":"ya29.a0","expires_in":3599,"refresh_token":"1//04x"}"#
            let refreshed = #"{"access_token":"ya29.b1","expires_in":3599}"#
            let token = YouTubeAPI.decodeToken(Data(full.utf8))
            Check.ok(token?.access == "ya29.a0", "access")
            Check.ok(token?.refresh == "1//04x", "refresh")
            Check.eq(token?.expiresIn ?? 0, 3599, "lifetime")
            Check.ok(YouTubeAPI.decodeToken(Data(refreshed.utf8))?.refresh == nil,
                     "a refresh response has no refresh token — the old one stands")
            Check.ok(YouTubeAPI.decodeToken(Data(#"{"error":"invalid_grant"}"#.utf8)) == nil,
                     "an error is not a token")
        }

        Check.run("consent URL carries PKCE and asks for a refresh token") {
            let url = YouTubeAPI.authorizationURL(
                clientID: "cid", redirect: "http://127.0.0.1:49152",
                challenge: "chal", state: "st")?.absoluteString ?? ""
            Check.ok(url.contains("code_challenge=chal"), "challenge")
            Check.ok(url.contains("code_challenge_method=S256"), "S256")
            Check.ok(url.contains("access_type=offline"), "offline")
            Check.ok(url.contains("prompt=consent"), "consent — without it, no refresh token")
            Check.ok(url.contains("state=st"), "state")
            Check.ok(url.contains("youtube.readonly"), "read-only scope")
        }

        Check.run("callback is read off the raw request line") {
            let ok = YouTubeAPI.parseCallback(
                requestLine: "GET /?code=4/0AX4&state=abc HTTP/1.1")
            Check.ok(ok.code == "4/0AX4", "code, slash intact — got \(ok.code ?? "nil")")
            Check.ok(ok.state == "abc", "state")
            Check.ok(ok.error == nil, "no error")

            let denied = YouTubeAPI.parseCallback(
                requestLine: "GET /?error=access_denied&state=abc HTTP/1.1")
            Check.ok(denied.error == "access_denied", "denial")
            Check.ok(denied.code == nil, "no code")

            let favicon = YouTubeAPI.parseCallback(requestLine: "GET /favicon.ico HTTP/1.1")
            Check.ok(favicon.code == nil && favicon.error == nil, "unrelated request yields nothing")
            Check.ok(YouTubeAPI.parseCallback(requestLine: "").code == nil, "empty line")
        }

        Check.run("form bodies escape what Google rejects unescaped") {
            let body = String(decoding: YouTubeAPI.form(["code": "4/0AX4+a=b", "id": "x y"]),
                              as: UTF8.self)
            Check.ok(body.contains("4%2F0AX4%2Ba%3Db"), "slash, plus and equals — got \(body)")
            Check.ok(body.contains("x%20y"), "space")
            Check.ok(!body.contains("+a"), "no raw plus, which would decode as a space")
        }
    }
}
