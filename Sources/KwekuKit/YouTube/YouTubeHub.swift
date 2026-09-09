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

        guard let id = await YouTubeChannelID.resolve(input) else {
            lastError = "Couldn't find a channel at that link"
            return nil
        }
        guard let url = YouTubeFeed.feedURL(channelId: id),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else {
            lastError = "That channel has no readable feed"
            return nil
        }

        // The feed is the title's only source now that there's no API. A
        // channel that has never uploaded has no entries and therefore no
        // name here; fall back to what was typed rather than refusing it.
        let uploads = YouTubeFeed.parse(data)
        let title = uploads.first?.channelTitle
            ?? input.trimmingCharacters(in: .whitespacesAndNewlines)

        store.add(YouTubeChannel(id: id, title: title))

        // Absorb the backlog now, while you're still looking at the menu you
        // changed, rather than announcing fifteen old videos at the next poll.
        if !store.isPrimed(id) {
            store.markSeen(uploads.map(\.id))
            store.remember(uploads: Array(uploads.prefix(5)))
            store.markPrimed(id)
        }
        lastError = nil
        start()
        return title
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

        for channel in channels {
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
                uploads, seen: store.seen, notifying: store.notifyingIDs)
            guard !fresh.isEmpty else { continue }

            store.markSeen(fresh.map(\.id))
            store.remember(uploads: fresh)
            for upload in fresh { onUpload?(upload) }
        }
    }
}
