import AppKit

/// Keeps the subscription list current and watches starred channels for uploads.
///
/// Two clocks, because the two jobs have nothing to do with each other. The
/// subscription list changes when *you* subscribe to something, which is rare
/// and costs quota to read — once a day. Uploads land whenever a creator
/// presses publish, cost nothing to check, and are the entire point — every
/// few minutes.
///
/// It knows nothing about drops. What the notch says is the content root's
/// business; this only reports that something landed.
@MainActor
public final class YouTubeHub: ObservableObject {

    @Published public private(set) var syncing = false
    /// Last thing that went wrong, for the menu to show. Nil once it works.
    @Published public private(set) var lastError: String?

    public let store: YouTubeStore
    public let oauth: YouTubeOAuth

    /// A new upload from a starred channel. Wired to the drop queue upstream.
    public var onUpload: ((YouTubeUpload) -> Void)?

    /// How often starred feeds are read. Five minutes is well inside what the
    /// feeds tolerate unauthenticated, and "within five minutes of publish" is
    /// as timely as this needs to be — it is a notice, not a race.
    private static let pollInterval: TimeInterval = 300
    /// The subscription list is re-read once a day.
    private static let syncInterval: TimeInterval = 24 * 3600

    private var timer: Timer?
    private var polling = false

    public init(store: YouTubeStore? = nil) {
        let store = store ?? YouTubeStore()
        self.store = store
        self.oauth = YouTubeOAuth(store: store)
    }

    public var isConnected: Bool { oauth.isConnected }

    // MARK: - Lifecycle

    /// Begin watching. Safe to call repeatedly; a no-op until connected.
    ///
    /// Unlike weather, this is not gated on the mode being visible. A notice
    /// you only receive while already looking at the thing that would tell you
    /// is not a notice.
    public func start() {
        timer?.invalidate(); timer = nil
        guard isConnected else { return }

        Task { await tick() }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.tick() }
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate(); timer = nil
    }

    /// Hand back the tokens and stop.
    public func disconnect() {
        stop()
        oauth.disconnect()
    }

    /// Run the consent flow, then sync and start watching.
    public func connect() async {
        do {
            try await oauth.connect()
            lastError = nil
            await syncSubscriptions()
            start()
        } catch {
            lastError = Self.describe(error)
        }
    }

    // MARK: - The two jobs

    private func tick() async {
        if let last = store.lastSyncedAt, Date().timeIntervalSince(last) < Self.syncInterval {
            await pollStarred()
        } else {
            await syncSubscriptions()
            await pollStarred()
        }
    }

    /// Re-read the subscription list, following every page.
    public func syncSubscriptions() async {
        guard isConnected, !syncing else { return }
        syncing = true
        defer { syncing = false }

        guard let token = try? await oauth.accessToken() else {
            lastError = "YouTube sign-in expired — connect again"
            return
        }

        var collected: [YouTubeChannel] = []
        var page: String?
        // Bounded rather than `while true`: a server that keeps handing back a
        // page token would otherwise spin here forever burning quota.
        for _ in 0..<40 {
            var request = URLRequest(url: YouTubeAPI.subscriptionsURL(pageToken: page))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = YouTubeAPI.decodeSubscriptions(data)
            else {
                lastError = "Couldn't read subscriptions"
                return
            }
            collected.append(contentsOf: decoded.channels)
            guard let next = decoded.nextPage else { break }
            page = next
        }

        store.merge(synced: collected)
        lastError = nil
    }

    /// Read every starred channel's feed and report what's new.
    public func pollStarred() async {
        guard !polling else { return }
        let starred = store.starredChannels
        guard !starred.isEmpty else { return }
        polling = true
        defer { polling = false }

        for channel in starred {
            guard let url = YouTubeFeed.feedURL(channelId: channel.id) else { continue }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { continue }

            let uploads = YouTubeFeed.parse(data)
            guard !uploads.isEmpty else { continue }

            // First read of this channel is its backlog: absorb it silently.
            guard store.isPrimed(channel.id) else {
                store.markSeen(uploads.map(\.id))
                store.remember(uploads: Array(uploads.prefix(5)))
                store.markPrimed(channel.id)
                continue
            }

            let fresh = YouTubeUploadPolicy.announceable(
                uploads, seen: store.seen, starred: store.starredIDs)
            guard !fresh.isEmpty else { continue }

            store.markSeen(fresh.map(\.id))
            store.remember(uploads: fresh)
            for upload in fresh { onUpload?(upload) }
        }
    }

    /// Starring a channel primes it now rather than at the next poll, so the
    /// panel has its recent uploads immediately and the backlog is absorbed
    /// while you are still looking at the list you changed.
    public func setStarred(_ starred: Bool, for channelID: String) {
        store.setStarred(starred, for: channelID)
        guard starred, !store.isPrimed(channelID) else { return }
        Task { await pollStarred() }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case YouTubeOAuth.Failure.notConfigured: return "Add your Google OAuth client first"
        case YouTubeOAuth.Failure.listenerFailed: return "Couldn't open the local callback"
        case YouTubeOAuth.Failure.denied(let why): return "Consent didn't complete (\(why))"
        case YouTubeOAuth.Failure.noRefreshToken: return "Google didn't return a refresh token"
        default: return "Couldn't connect to YouTube"
        }
    }
}
