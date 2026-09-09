import AppKit
import CryptoKit

/// The consent flow, and the access token it eventually yields.
///
/// Loopback redirect (RFC 8252), which is the only interactive flow Google
/// still supports for a desktop app — the old out-of-band "copy this code"
/// form was switched off in 2022. Kweku opens a browser tab, listens on
/// `127.0.0.1` on an ephemeral port for exactly one request, and shuts the
/// listener down the moment it has the code.
///
/// Nothing here writes to the keychain and nothing triggers a privilege
/// prompt: the tokens live in app preferences alongside the Gemini key, the
/// same trade this app already makes. A refresh token is a bearer credential
/// for read-only access to your subscription list, so that is a real trade and
/// not a free one — revoke it at myaccount.google.com/permissions if the
/// machine ever leaves your hands.
@MainActor
public final class YouTubeOAuth {

    public enum Failure: Error, Equatable {
        case notConfigured
        case listenerFailed
        case denied(String)
        case exchangeFailed
        case noRefreshToken
    }

    private let store: YouTubeStore
    /// In-memory access token; deliberately not persisted — it lives an hour,
    /// and the refresh token can always mint another.
    private var access: String?
    private var accessExpiry = Date.distantPast

    public init(store: YouTubeStore) { self.store = store }

    public var isConnected: Bool { store.refreshToken != nil }

    // MARK: - Consent

    /// Run the full consent flow. Returns once tokens are stored.
    public func connect() async throws {
        guard let clientID = store.clientID, let secret = store.clientSecret else {
            throw Failure.notConfigured
        }

        let verifier = Self.randomURLSafe(bytes: 64)
        let challenge = Self.challenge(for: verifier)
        let state = Self.randomURLSafe(bytes: 16)

        let listener = LoopbackListener()
        guard let port = listener.start() else { throw Failure.listenerFailed }
        defer { listener.stop() }

        let redirect = "http://127.0.0.1:\(port)"
        guard let url = YouTubeAPI.authorizationURL(clientID: clientID, redirect: redirect,
                                                    challenge: challenge, state: state) else {
            throw Failure.listenerFailed
        }
        NSWorkspace.shared.open(url)

        let requestLine = try await listener.awaitRequest()
        let callback = YouTubeAPI.parseCallback(requestLine: requestLine)

        if let error = callback.error { throw Failure.denied(error) }
        // A mismatched state means the request on the socket did not come from
        // the consent screen we opened. Ignore it rather than exchanging it.
        guard callback.state == state, let code = callback.code else {
            throw Failure.denied("state mismatch")
        }

        let body = YouTubeAPI.tokenExchangeBody(clientID: clientID, clientSecret: secret,
                                                code: code, verifier: verifier,
                                                redirect: redirect)
        guard let token = try await post(body) else { throw Failure.exchangeFailed }
        guard let refresh = token.refresh else { throw Failure.noRefreshToken }

        store.refreshToken = refresh
        access = token.access
        accessExpiry = Date().addingTimeInterval(token.expiresIn - 60)
    }

    public func disconnect() {
        store.refreshToken = nil
        access = nil
        accessExpiry = .distantPast
    }

    // MARK: - Access tokens

    /// A usable access token, refreshed if the one in hand has expired.
    public func accessToken() async throws -> String {
        if let access, Date() < accessExpiry { return access }
        guard let clientID = store.clientID, let secret = store.clientSecret else {
            throw Failure.notConfigured
        }
        guard let refresh = store.refreshToken else { throw Failure.noRefreshToken }

        let body = YouTubeAPI.refreshBody(clientID: clientID, clientSecret: secret,
                                          refreshToken: refresh)
        guard let token = try await post(body) else {
            // A refresh token dies for several reasons that all look identical
            // here and all mean "consent again": revoked from the account's
            // permissions page, unused for six months, or — the one that
            // actually bites — the consent screen still being in *Testing*
            // publishing status, which caps every refresh token at 7 days for
            // any scope beyond name/email/profile. Publish the app to stop
            // that; verification is only needed to drop the unverified-app
            // warning, not to keep a token alive.
            store.refreshToken = nil
            throw Failure.exchangeFailed
        }
        access = token.access
        accessExpiry = Date().addingTimeInterval(token.expiresIn - 60)
        // Google rotates refresh tokens for some client types; keep the new
        // one when it sends it, keep the old one when it doesn't.
        if let rotated = token.refresh { store.refreshToken = rotated }
        return token.access
    }

    private func post(_ body: Data) async throws
        -> (access: String, expiresIn: TimeInterval, refresh: String?)? {
        var request = URLRequest(url: URL(string: YouTubeAPI.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return YouTubeAPI.decodeToken(data)
    }

    // MARK: - PKCE

    /// base64url, unpadded — the only alphabet PKCE and OAuth state accept.
    ///
    /// `SystemRandomNumberGenerator` is the platform CSPRNG on Apple systems,
    /// which is the bar a PKCE verifier has to clear.
    static func randomURLSafe(bytes count: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP listener on loopback, for the length of one consent screen.
///
/// Binds to port 0 and asks the kernel which port it got, so the flow never
/// collides with something already listening and never needs a fixed port
/// registered in the OAuth client. Google allows any port on `127.0.0.1`
/// precisely so installed apps can do this.
///
/// `@unchecked Sendable` is honest here rather than a shrug: every mutable
/// field is touched only from `queue`, which is serial, and the two things
/// that can race — the accepted request and the timeout — are funnelled
/// through `finish` on that same queue.
private final class LoopbackListener: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.kweku.youtube.oauth")
    private var acceptSource: DispatchSourceRead?
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false

    /// Bind and listen. Returns the port the kernel assigned.
    func start() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // kernel picks
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); return nil }
        // Non-blocking, because the accept is driven by a dispatch source
        // rather than by parking a thread on it. A blocking accept on this
        // serial queue would also block the timeout that is supposed to
        // rescue us from it.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { close(fd); return nil }

        listenFD = fd
        return UInt16(bigEndian: actual.sin_port)
    }

    /// Wait for the browser to come back, with a bound on how long.
    ///
    /// Five minutes is roughly how long a Google consent screen can reasonably
    /// take including a login and a device prompt; past that the tab was
    /// almost certainly abandoned, and a socket left open forever is worse
    /// than a flow you can start again.
    func awaitRequest(timeout: TimeInterval = 300) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.listenFD >= 0 else {
                    continuation.resume(throwing: YouTubeOAuth.Failure.listenerFailed)
                    return
                }
                self.continuation = continuation

                let source = DispatchSource.makeReadSource(fileDescriptor: self.listenFD,
                                                           queue: self.queue)
                source.setEventHandler { self.acceptPending() }
                source.resume()
                self.acceptSource = source

                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(YouTubeOAuth.Failure.denied("timed out")))
                }
            }
        }
    }

    /// Read the one request the browser makes, answer it, and we're done.
    private func acceptPending() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        // The browser has already written the request line by the time the
        // source fires, but a socket that goes quiet must not wedge the queue.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(client, &buffer, buffer.count)
        let request = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
        let line = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""

        // Browsers routinely follow up with /favicon.ico on the same origin.
        // Answering it as if it were the callback would end the flow with a
        // request that has no code in it.
        guard line.contains("code=") || line.contains("error=") else {
            Self.respond(on: client, ok: false)
            return
        }
        Self.respond(on: client, ok: line.contains("code="))
        finish(.success(line))
    }

    /// What the browser tab is left showing. The tab is the only surface the
    /// user is looking at during this flow, so it has to say how it went.
    private static func respond(on fd: Int32, ok: Bool) {
        let message = ok
            ? "<h2>Kweku is connected.</h2><p>You can close this tab.</p>"
            : "<h2>Kweku didn't get the code.</h2><p>Try connecting again.</p>"
        let html = """
        <!doctype html><meta charset=utf-8>
        <title>Kweku</title>
        <body style="font:16px -apple-system,system-ui;display:grid;place-items:center;\
        height:90vh;margin:0;color:#eee;background:#111;text-align:center">
        <div>\(message)</div></body>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        _ = Array(response.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// Resume the continuation exactly once, whichever path got here first —
    /// the accepted request or the timeout.
    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
        }
    }

    deinit { stop() }
}
