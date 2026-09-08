import Foundation

/// Everything about YouTube that has to survive a relaunch.
///
/// Preferences rather than the keychain, matching how the Gemini key is
/// already held: this app is an ad-hoc-signed dylib loaded by a frozen host,
/// and the standing rule on this machine is that nothing may depend on a
/// keychain write or an authorisation prompt to work.
@MainActor
public final class YouTubeStore: ObservableObject {

    /// Every subscription, starred or not. The unstarred ones are still worth
    /// keeping: they are the list you pick from, and re-syncing to offer that
    /// list would cost a round trip every time the menu opens.
    @Published public private(set) var channels: [YouTubeChannel] = []
    @Published public private(set) var lastSyncedAt: Date?
    /// The most recent uploads seen across starred channels, newest first —
    /// what the panel shows when you open the notch on it.
    @Published public private(set) var recent: [YouTubeUpload] = []

    private enum Key {
        static let clientID = "youtubeClientID"
        static let clientSecret = "youtubeClientSecret"
        static let refreshToken = "youtubeRefreshToken"
        static let channels = "youtubeChannels"
        static let seen = "youtubeSeenVideoIDs"
        static let recent = "youtubeRecentUploads"
        static let lastSync = "youtubeLastSyncedAt"
        static let primed = "youtubePrimedChannels"
    }

    /// How many video ids to remember.
    ///
    /// The dedupe set only has to outlive the feed window: a channel's Atom
    /// feed carries ~15 entries, so an id can only reappear while it is still
    /// in that window. A few hundred covers a large starred list many times
    /// over, and the cap stops preferences growing without bound for years.
    private static let seenLimit = 600
    /// How many uploads the panel keeps.
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
        lastSyncedAt = defaults.object(forKey: Key.lastSync) as? Date
    }

    // MARK: - Credentials

    /// The OAuth client from your Google Cloud project. Not a secret in the
    /// usual sense — RFC 8252 is explicit that an installed app cannot keep
    /// one — which is why PKCE carries the actual protection.
    public var clientID: String? { nonEmpty(Key.clientID) }
    public var clientSecret: String? { nonEmpty(Key.clientSecret) }

    public var refreshToken: String? {
        get { nonEmpty(Key.refreshToken) }
        set { defaults.set(newValue, forKey: Key.refreshToken) }
    }

    public var hasClient: Bool { clientID != nil && clientSecret != nil }

    public func storeClient(id: String, secret: String) {
        defaults.set(id, forKey: Key.clientID)
        defaults.set(secret, forKey: Key.clientSecret)
    }

    /// Forget the connection entirely, credentials included.
    public func forgetEverything() {
        for key in [Key.clientID, Key.clientSecret, Key.refreshToken, Key.channels,
                    Key.seen, Key.recent, Key.lastSync, Key.primed] {
            defaults.removeObject(forKey: key)
        }
        channels = []; recent = []
        seenIDs = []; seenOrder = []
        primedIDs = []
        lastSyncedAt = nil
    }

    // MARK: - Channels

    /// Replace the subscription list with a freshly synced one.
    ///
    /// Stars are carried across by id, never taken from the incoming list —
    /// the API has no idea which channels you starred, so a naive overwrite
    /// would silently un-star everything on the next daily sync.
    public func merge(synced: [YouTubeChannel]) {
        let stars = Set(channels.filter(\.starred).map(\.id))
        channels = synced.map { channel in
            var copy = channel
            copy.starred = stars.contains(channel.id)
            return copy
        }
        lastSyncedAt = Date()
        defaults.set(lastSyncedAt, forKey: Key.lastSync)
        persistChannels()
    }

    public func setStarred(_ starred: Bool, for channelID: String) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        channels[index].starred = starred
        persistChannels()
    }

    public var starredChannels: [YouTubeChannel] { channels.filter(\.starred) }
    public var starredIDs: Set<String> { Set(starredChannels.map(\.id)) }

    // MARK: - Seen uploads

    public var seen: Set<String> { seenIDs }

    /// Record ids as already said, so they are never announced again.
    ///
    /// Also the first-poll suppressor: a newly starred channel has its whole
    /// current feed marked seen without announcing any of it, which is why
    /// starring someone doesn't immediately cost you fifteen notices about
    /// videos from last month.
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
    /// starring someone is swallowed whole, and only what lands *afterwards*
    /// is worth opening the notch for.
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

    private func nonEmpty(_ key: String) -> String? {
        let value = defaults.string(forKey: key)
        return (value?.isEmpty == false) ? value : nil
    }
}
