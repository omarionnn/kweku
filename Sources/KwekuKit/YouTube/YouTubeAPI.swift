import Foundation

/// The Data API, reached with nothing but an API key.
///
/// The public Atom feed turned out to be unreliable — a sampled 7 of 8
/// channels returned 404, including ones that had answered minutes earlier, so
/// it degrades under repeated use rather than failing honestly. That is fine
/// for a feed reader someone refreshes by hand and useless for a thing that
/// polls all day.
///
/// This needs no OAuth. Reading *your subscriptions* is private and needs a
/// consent screen, a published app and a token that expires; reading *a named
/// channel's uploads* is public, and a key is enough. Since the channels are
/// named by hand now, a key is all this ever needed.
///
/// Quota: `playlistItems.list` and `channels.list` cost 1 unit each against a
/// free 10,000/day. A dozen channels polled every five minutes is ~3,500.
public enum YouTubeAPI {

    private static let base = "https://www.googleapis.com/youtube/v3/"

    /// Every channel's uploads live in a playlist whose id is the channel's
    /// with `UC` swapped for `UU`. Undocumented but load-bearing for a decade,
    /// and it saves a `channels.list` round trip per poll.
    public static func uploadsPlaylistID(forChannel id: String) -> String? {
        guard id.count > 2, id.hasPrefix("UC") else { return nil }
        return "UU" + id.dropFirst(2)
    }

    public static func uploadsURL(channelID: String, key: String, limit: Int = 10) -> URL? {
        guard let playlist = uploadsPlaylistID(forChannel: channelID) else { return nil }
        var c = URLComponents(string: base + "playlistItems")
        c?.queryItems = [
            // `contentDetails` carries the real upload time; `snippet`'s
            // publishedAt is when the video entered the playlist, which for a
            // backfilled or re-ordered uploads list is a different date.
            .init(name: "part", value: "snippet,contentDetails"),
            .init(name: "playlistId", value: playlist),
            .init(name: "maxResults", value: String(limit)),
            .init(name: "key", value: key),
        ]
        return c?.url
    }

    public static func decodeUploads(_ data: Data) -> [YouTubeUpload]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // A bad key or a disabled API answers 200-shaped JSON with an error
        // body in some paths; treat anything carrying `error` as a failure so
        // the caller can fall back rather than reporting "no new uploads".
        if obj["error"] != nil { return nil }
        guard let items = obj["items"] as? [[String: Any]] else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        return items.compactMap { item -> YouTubeUpload? in
            guard let snippet = item["snippet"] as? [String: Any],
                  let resource = snippet["resourceId"] as? [String: Any],
                  let videoID = resource["videoId"] as? String,
                  let title = snippet["title"] as? String
            else { return nil }

            let details = item["contentDetails"] as? [String: Any]
            let stamp = (details?["videoPublishedAt"] as? String)
                ?? (snippet["publishedAt"] as? String) ?? ""
            guard let published = iso.date(from: stamp) ?? plain.date(from: stamp) else {
                return nil
            }
            // A private or deleted video stays in the playlist as a tombstone
            // with no owner and a placeholder title. Announcing "Private
            // video" would be worse than saying nothing.
            let owner = (snippet["videoOwnerChannelTitle"] as? String)
                ?? (snippet["channelTitle"] as? String) ?? ""
            guard !owner.isEmpty, title != "Private video", title != "Deleted video" else {
                return nil
            }
            let channelID = (snippet["videoOwnerChannelId"] as? String)
                ?? (snippet["channelId"] as? String) ?? ""

            return YouTubeUpload(id: videoID, channelId: channelID, channelTitle: owner,
                                 title: title, published: published)
        }
        .sorted { $0.published > $1.published }
    }

    // MARK: - Resolving a channel

    /// Look a channel up by id, `@handle`, or legacy username.
    ///
    /// One unit, and it answers with the canonical title — which the page
    /// scrape can only get by then reading the feed as well.
    public static func lookupURL(for input: String, key: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var c = URLComponents(string: base + "channels")
        var items = [URLQueryItem(name: "part", value: "snippet"),
                     URLQueryItem(name: "key", value: key)]

        if let id = YouTubeChannelID.direct(from: trimmed) {
            items.append(.init(name: "id", value: id))
        } else if let handle = handle(in: trimmed) {
            items.append(.init(name: "forHandle", value: handle))
        } else {
            return nil
        }
        c?.queryItems = items
        return c?.url
    }

    /// The `@handle` inside whatever was pasted, if there is one.
    ///
    /// A bare word counts: it is what someone types when they mean a handle,
    /// and it is the only reading that could succeed.
    public static func handle(in input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.range(of: "/@") {
            let tail = trimmed[at.upperBound...]
            let name = String(tail.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
            return name.isEmpty ? nil : "@" + name
        }
        if trimmed.hasPrefix("@") { return trimmed }
        // A URL that isn't a handle URL can't be reduced to one.
        if trimmed.contains("/") || trimmed.contains(".") { return nil }
        return "@" + trimmed
    }

    public static func decodeChannel(_ data: Data) -> YouTubeChannel? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["error"] == nil,
              let items = obj["items"] as? [[String: Any]],
              let first = items.first,
              let id = first["id"] as? String,
              let snippet = first["snippet"] as? [String: Any],
              let title = snippet["title"] as? String
        else { return nil }
        return YouTubeChannel(id: id, title: title)
    }
}
