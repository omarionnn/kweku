import Foundation

/// The one thing the public feeds cannot tell us: who you are subscribed to.
///
/// `subscriptions.list?mine=true` is OAuth-only — there is no API-key form of
/// "my subscriptions", because it is private user data. So the Data API is
/// used for exactly this, once a day, at 1 quota unit per 50 channels. Uploads
/// never touch it; see `YouTubeFeed`.
public enum YouTubeAPI {

    /// Read-only, and the narrowest scope that can list subscriptions.
    public static let scope = "https://www.googleapis.com/auth/youtube.readonly"

    public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    // MARK: - Subscriptions

    public static func subscriptionsURL(pageToken: String? = nil) -> URL {
        var c = URLComponents(string: "https://www.googleapis.com/youtube/v3/subscriptions")!
        c.queryItems = [
            .init(name: "part", value: "snippet"),
            .init(name: "mine", value: "true"),
            .init(name: "maxResults", value: "50"),
            .init(name: "order", value: "alphabetical"),
        ]
        if let pageToken { c.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
        return c.url!
    }

    /// One page of subscriptions plus the cursor to the next.
    ///
    /// The channel id lives at `snippet.resourceId.channelId` — *not* at the
    /// subscription's own `id`, which identifies the act of subscribing rather
    /// than the channel subscribed to. Reading the wrong one yields ids that
    /// no feed will ever answer for.
    public static func decodeSubscriptions(_ data: Data)
        -> (channels: [YouTubeChannel], nextPage: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]]
        else { return nil }

        let channels: [YouTubeChannel] = items.compactMap { item in
            guard let snippet = item["snippet"] as? [String: Any],
                  let resource = snippet["resourceId"] as? [String: Any],
                  let id = resource["channelId"] as? String,
                  let title = snippet["title"] as? String
            else { return nil }
            let thumbs = snippet["thumbnails"] as? [String: Any]
            let def = thumbs?["default"] as? [String: Any]
            let avatar = (def?["url"] as? String).flatMap(URL.init(string:))
            return YouTubeChannel(id: id, title: title, avatarURL: avatar)
        }
        return (channels, obj["nextPageToken"] as? String)
    }

    // MARK: - OAuth payloads

    /// The consent URL for the loopback flow (RFC 8252).
    ///
    /// `access_type=offline` with `prompt=consent` is what makes Google return
    /// a refresh token. Without both, a re-authorisation returns only an access
    /// token that dies in an hour, and the next launch is silently logged out.
    public static func authorizationURL(clientID: String, redirect: String,
                                        challenge: String, state: String) -> URL? {
        var c = URLComponents(string: authEndpoint)
        c?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        return c?.url
    }

    public static func tokenExchangeBody(clientID: String, clientSecret: String,
                                         code: String, verifier: String,
                                         redirect: String) -> Data {
        form([
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
        ])
    }

    public static func refreshBody(clientID: String, clientSecret: String,
                                   refreshToken: String) -> Data {
        form([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    /// Access token, its lifetime, and a refresh token when one was issued.
    ///
    /// A refresh response deliberately omits `refresh_token` — the original
    /// stays valid — so this is optional and callers must keep the one they
    /// already hold rather than overwriting it with nil.
    public static func decodeToken(_ data: Data)
        -> (access: String, expiresIn: TimeInterval, refresh: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else { return nil }
        let expires = (obj["expires_in"] as? Double) ?? 3600
        return (access, expires, obj["refresh_token"] as? String)
    }

    /// `application/x-www-form-urlencoded`, escaping every reserved character.
    ///
    /// Client secrets and authorisation codes routinely contain `-` and `_`
    /// but also `/` and `+`; the default allowed-character sets leave those
    /// intact and Google rejects the result as an invalid grant.
    public static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// Pull `code` / `state` / `error` out of the browser's redirect request line.
    ///
    /// The loopback listener gets a raw HTTP request, not a parsed URL, so the
    /// first line — `GET /?code=…&state=… HTTP/1.1` — is what there is to work
    /// with. Split out as a pure function because an OAuth callback is
    /// otherwise only reachable by completing a real consent screen.
    public static func parseCallback(requestLine: String)
        -> (code: String?, state: String?, error: String?) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return (nil, nil, nil) }
        var c = URLComponents()
        c.query = parts[1].split(separator: "?", maxSplits: 1).last.map(String.init) ?? ""
        let items = c.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        return (value("code"), value("state"), value("error"))
    }
}
