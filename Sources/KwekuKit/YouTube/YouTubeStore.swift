import Foundation

/// The channels you follow, and what has already been said about them.
///
/// No credentials live here any more. Following a channel by id needs no
/// account, no consent screen and nothing that expires — the only state worth
/// keeping is which channels you named, which uploads have been announced, and
/// the handful worth showing when you open the notch.
@MainActor
public final class YouTubeStore: ObservableObject {

    /// Channels you added, in the order you added them.
    @Published public private(set) var channels: [YouTubeChannel] = []
    /// The most recent uploads across those channels, newest first.
    @Published public private(set) var recent: [YouTubeUpload] = []

    private enum Key {
        static let channels = "youtubeChannels"
        static let seen = "youtubeSeenVideoIDs"
        static let recent = "youtubeRecentUploads"
        static let primed = "youtubePrimedChannels"
        static let apiKey = "youtubeAPIKey"
    }

    /// How many video ids to remember.
    ///
    /// The dedupe set only has to outlive the feed window: a channel's Atom
    /// feed carries ~15 entries, so an id can only reappear while it is still
    /// in that window. A few hundred covers a large list many times over, and
    /// the cap stops preferences growing without bound for years.
    private static let seenLimit = 600
    private static let recentLimit = 40

    private let defaults: UserDefaults
    /// Insertion-ordered so the oldest ids can be dropped when trimming; the
    /// set is the membership test, the array is the order.
    private var seenIDs: Set<String> = []
    private var seenOrder: [String] = []
    /// Channels whose feed has been read at least once.
    private var primedIDs: Set<String> = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        channels = decode([YouTubeChannel].self, Key.channels) ?? []
        recent = decode([YouTubeUpload].self, Key.recent) ?? []
        seenOrder = defaults.stringArray(forKey: Key.seen) ?? []
        seenIDs = Set(seenOrder)
        primedIDs = Set(defaults.stringArray(forKey: Key.primed) ?? [])
    }

    // MARK: - API key

    /// A plain Data API key. Not a credential for *you* — it identifies the
    /// caller, not the user, and grants nothing but public reads. Optional:
    /// without it uploads come from the Atom feed, which needs no setup but
    /// answers 404 for a lot of channels.
    public var apiKey: String? {
        get {
            if let env = ProcessInfo.processInfo.environment["YOUTUBE_API_KEY"], !env.isEmpty {
                return env
            }
            let stored = defaults.string(forKey: Key.apiKey)
            return (stored?.isEmpty == false) ? stored : nil
        }
        set {
            defaults.set(newValue, forKey: Key.apiKey)
            objectWillChange.send()
        }
    }

    // MARK: - Channels

    public var isEmpty: Bool { channels.isEmpty }
    /// Channels currently allowed to open the notch.
    public var notifyingIDs: Set<String> { Set(channels.filter(\.notifies).map(\.id)) }

    public func contains(_ channelID: String) -> Bool {
        channels.contains { $0.id == channelID }
    }

    /// Add a channel, or update the title of one already followed.
    @discardableResult
    public func add(_ channel: YouTubeChannel) -> Bool {
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            // Re-adding is how you'd fix a channel that was named before it
            // had a title; it must not silently reset the notify switch.
            channels[index].title = channel.title
            persistChannels()
            return false
        }
        channels.append(channel)
        persistChannels()
        return true
    }

    public func remove(_ channelID: String) {
        channels.removeAll { $0.id == channelID }
        primedIDs.remove(channelID)
        defaults.set(Array(primedIDs), forKey: Key.primed)
        persistChannels()
    }

    /// The per-channel quiet switch, for someone who posts five times a day
    /// and whom you'd rather read in the panel than be told about.
    public func setNotifies(_ notifies: Bool, for channelID: String) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        channels[index].notifies = notifies
        persistChannels()
    }

    // MARK: - Seen uploads

    public var seen: Set<String> { seenIDs }

    /// Record ids as already said, so they are never announced again.
    public func markSeen(_ ids: [String]) {
        for id in ids where !seenIDs.contains(id) {
            seenIDs.insert(id)
            seenOrder.append(id)
        }
        let overflow = seenOrder.count - Self.seenLimit
        if overflow > 0 {
            for id in seenOrder.prefix(overflow) { seenIDs.remove(id) }
            seenOrder.removeFirst(overflow)
        }
        defaults.set(seenOrder, forKey: Key.seen)
    }

    /// Has this channel's feed ever been read?
    ///
    /// The first read of a channel is a backlog, not news — the feed hands
    /// back its last ~15 uploads whenever you ask. So the first poll after
    /// adding someone is swallowed whole, and only what lands *afterwards* is
    /// worth opening the notch for.
    public func isPrimed(_ channelID: String) -> Bool { primedIDs.contains(channelID) }

    public func markPrimed(_ channelID: String) {
        guard !primedIDs.contains(channelID) else { return }
        primedIDs.insert(channelID)
        defaults.set(Array(primedIDs), forKey: Key.primed)
    }

    /// Add to the panel's list, newest first, without duplicating.
    public func remember(uploads: [YouTubeUpload]) {
        guard !uploads.isEmpty else { return }
        var merged = recent
        for upload in uploads where !merged.contains(where: { $0.id == upload.id }) {
            merged.append(upload)
        }
        merged.sort { $0.published > $1.published }
        recent = Array(merged.prefix(Self.recentLimit))
        if let data = try? JSONEncoder().encode(recent) {
            defaults.set(data, forKey: Key.recent)
        }
    }

    /// Forget every channel and everything said about them.
    public func forgetEverything() {
        for key in [Key.channels, Key.seen, Key.recent, Key.primed] {
            defaults.removeObject(forKey: key)
        }
        channels = []; recent = []
        seenIDs = []; seenOrder = []
        primedIDs = []
    }

    // MARK: - Plumbing

    private func persistChannels() {
        if let data = try? JSONEncoder().encode(channels) {
            defaults.set(data, forKey: Key.channels)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
