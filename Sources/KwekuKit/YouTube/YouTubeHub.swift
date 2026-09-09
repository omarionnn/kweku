import AppKit
import Combine

/// Watches the channels you follow for new uploads.
///
/// One clock now, not two. Reading your Google subscription list needed OAuth,
/// a published consent screen and a token that expired; naming channels
/// yourself needs none of it, and the uploads were always going to come from
/// the public Atom feed regardless. What's left is a poll.
///
/// It knows nothing about drops. What the notch says is the content root's
/// business; this only reports that something landed.
@MainActor
public final class YouTubeHub: ObservableObject {

    /// Last thing that went wrong, for the menu to show. Nil once it works.
    @Published public private(set) var lastError: String?
    /// True while a pasted channel is being resolved.
    @Published public private(set) var adding = false

    public let store: YouTubeStore

    /// A new upload from a channel that may speak. Wired to the drop queue.
    public var onUpload: ((YouTubeUpload) -> Void)?

    /// How often feeds are read. Five minutes is well inside what the feeds
    /// tolerate unauthenticated, and "within five minutes of publish" is as
    /// timely as this needs to be — it is a notice, not a race.
    private static let pollInterval: TimeInterval = 300

    private var timer: Timer?
    private var polling = false
    private var storeChanges: AnyCancellable?

    public init(store: YouTubeStore? = nil) {
        let store = store ?? YouTubeStore()
        self.store = store
        // Republish the store's changes as our own.
        //
        // Views observe the hub, but the channel list lives on the store — a
        // separate `ObservableObject`, whose changes do *not* travel up an
        // enclosing one. Without this, adding a channel updates the model and
        // the menu carries on showing the old list until something unrelated
        // redraws it.
        storeChanges = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Lifecycle

    /// Begin watching. Safe to call repeatedly.
    ///
    /// Not gated on the mode being visible: a notice you only receive while
    /// already looking at the thing that would tell you is not a notice.
    public func start() {
        timer?.invalidate(); timer = nil
        guard !store.isEmpty else { return }

        Task { await poll() }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.poll() }
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate(); timer = nil
    }

    // MARK: - Following a channel

    /// Resolve whatever was pasted and start following it.
    ///
    /// Returns the channel's display name on success, so the caller can say
    /// *which* channel it just added rather than "done" — pasting a handle and
    /// being told only that it worked leaves you unsure you got the right one.
    @discardableResult
    public func addChannel(from input: String) async -> String? {
        adding = true
        defer { adding = false }

        // With a key, one call resolves the channel *and* names it. Without
        // one, fall back to reading the id out of the page.
        if let key = store.apiKey,
           let url = YouTubeAPI.lookupURL(for: input, key: key),
           let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let channel = YouTubeAPI.decodeChannel(data) {
            store.add(channel)
            await prime(channel.id)
            lastError = nil
            start()
            return channel.title
        }

        guard let id = await YouTubeChannelID.resolve(input) else {
            lastError = "Couldn't find a channel at that link"
            return nil
        }
        let uploads = await fetchUploads(channelID: id)
        // A channel with no readable uploads is still worth following — it may
        // simply not have posted yet, and with no key the feed may be refusing
        // us rather than the channel being empty. Name it from what was typed.
        let title = uploads?.first?.channelTitle
            ?? input.trimmingCharacters(in: .whitespacesAndNewlines)

        store.add(YouTubeChannel(id: id, title: title))

        // Absorb the backlog now, while you're still looking at the menu you
        // changed, rather than announcing fifteen old videos at the next poll.
        if let uploads, !store.isPrimed(id) {
            store.markSeen(uploads.map(\.id))
            store.remember(uploads: Array(uploads.prefix(5)))
            store.markPrimed(id)
        }
        lastError = nil
        start()
        return title
    }

    /// Swallow a newly followed channel's backlog so it is never announced.
    private func prime(_ channelID: String) async {
        guard !store.isPrimed(channelID),
              let uploads = await fetchUploads(channelID: channelID) else { return }
        store.markSeen(uploads.map(\.id))
        store.remember(uploads: Array(uploads.prefix(5)))
        store.markPrimed(channelID)
    }

    /// A channel's recent uploads: the Data API when a key is set, the public
    /// Atom feed otherwise.
    ///
    /// Nil means "couldn't read", which is different from "nothing new" — the
    /// caller must not treat a failed fetch as an empty channel and mark its
    /// backlog seen.
    private func fetchUploads(channelID: String) async -> [YouTubeUpload]? {
        if let key = store.apiKey,
           let url = YouTubeAPI.uploadsURL(channelID: channelID, key: key),
           let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let uploads = YouTubeAPI.decodeUploads(data) {
            return uploads
        }
        guard let url = YouTubeFeed.feedURL(channelId: channelID),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let parsed = YouTubeFeed.parse(data)
        return parsed.isEmpty ? nil : parsed
    }

    public func remove(_ channelID: String) {
        store.remove(channelID)
        if store.isEmpty { stop() }
    }

    public func setNotifies(_ notifies: Bool, for channelID: String) {
        store.setNotifies(notifies, for: channelID)
    }

    // MARK: - Polling

    /// Read every followed channel's feed and report what's new.
    public func poll() async {
        guard !polling else { return }
        let channels = store.channels
        guard !channels.isEmpty else { return }
        polling = true
        defer { polling = false }

        var unreadable = 0
        for channel in channels {
            guard let uploads = await fetchUploads(channelID: channel.id), !uploads.isEmpty else {
                unreadable += 1
                continue
            }

            // First read of this channel is its backlog: absorb it silently.
            guard store.isPrimed(channel.id) else {
                store.markSeen(uploads.map(\.id))
                store.remember(uploads: Array(uploads.prefix(5)))
                store.markPrimed(channel.id)
                continue
            }

            let fresh = YouTubeUploadPolicy.announceable(
                uploads, seen: store.seen, notifying: store.notifyingIDs)
            guard !fresh.isEmpty else { continue }

            store.markSeen(fresh.map(\.id))
            store.remember(uploads: fresh)
            for upload in fresh { onUpload?(upload) }
        }

        // Say so when the feeds are stonewalling rather than failing quietly
        // for days. Without a key this is common — the public feed answers 404
        // for a great many channels — and the menu is the only place that can
        // explain why a followed channel never says anything.
        if unreadable == channels.count, store.apiKey == nil {
            lastError = "Feeds unreadable — add a YouTube API key"
        } else if unreadable == 0 {
            lastError = nil
        }
    }
}
