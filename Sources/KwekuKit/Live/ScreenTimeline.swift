import Foundation

/// One remembered instant of screen: what was in front, and optionally the
/// frame itself.
public struct ScreenMoment: Codable, Equatable, Sendable {
    public var at: Date
    public var app: String
    public var title: String
    /// Filename of the stored JPEG, relative to the timeline directory. Nil
    /// for moments recorded without pixels — redacted windows, or the
    /// cheap title-only samples taken between full captures.
    public var frame: String?

    public init(at: Date, app: String, title: String, frame: String? = nil) {
        self.at = at; self.app = app; self.title = title; self.frame = frame
    }

    /// Marker used in place of a redacted window's real identity. The
    /// timeline is local, but a local file full of password-manager window
    /// titles is still a file full of password-manager window titles.
    public static let privateLabel = "(private window)"
}

/// Pure timeline logic: what to record, what to keep, and how to answer a
/// question about it. No I/O — `ScreenTimelineStore` does that.
///
/// This is the half of "what was I doing?" that has to be right. Human memory
/// of a screen is terrible and the machine's is perfect, so the only real
/// question is whether the recall can find the moment being described in the
/// vague terms people actually use ("that docs page", "the error before lunch").
public enum ScreenTimeline {

    /// Whether a new moment is worth storing. A window change is always worth
    /// it; otherwise sample slowly, because the interesting axis is *what was
    /// in front*, not how long it sat there.
    public static func shouldRecord(previous: ScreenMoment?,
                                    app: String,
                                    title: String,
                                    now: Date,
                                    sampleInterval: TimeInterval = 30) -> Bool {
        guard let previous else { return true }
        if previous.app != app || previous.title != title { return true }
        return now.timeIntervalSince(previous.at) >= sampleInterval
    }

    /// Keep the timeline bounded in both directions: nothing older than
    /// `maxAge`, and never more than `maxCount` moments.
    public static func prune(_ moments: [ScreenMoment],
                             now: Date,
                             maxAge: TimeInterval = 6 * 3600,
                             maxCount: Int = 600) -> [ScreenMoment] {
        let fresh = moments.filter { now.timeIntervalSince($0.at) <= maxAge }
        return fresh.count <= maxCount ? fresh : Array(fresh.suffix(maxCount))
    }

    /// Moments matching `query`, newest first.
    ///
    /// Every whitespace-separated word must appear somewhere in the app name
    /// or title. An empty query matches everything, which is what makes
    /// "what was I doing twenty minutes ago" work as a pure time slice.
    public static func search(_ moments: [ScreenMoment],
                              query: String,
                              within minutes: Double? = nil,
                              now: Date,
                              limit: Int = 12) -> [ScreenMoment] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let cutoff = minutes.map { now.addingTimeInterval(-$0 * 60) }
        let hits = moments.filter { moment in
            if let cutoff, moment.at < cutoff { return false }
            guard !words.isEmpty else { return true }
            let hay = "\(moment.app) \(moment.title)".lowercased()
            return words.allSatisfy(hay.contains)
        }
        return Array(hits.sorted { $0.at > $1.at }.prefix(limit))
    }

    /// Collapse consecutive moments of the same window into one line, so a
    /// window left open for an hour reads as one entry with a span rather
    /// than a hundred identical rows.
    public static func condense(_ moments: [ScreenMoment]) -> [(ScreenMoment, Date)] {
        var out: [(ScreenMoment, Date)] = []
        for moment in moments.sorted(by: { $0.at < $1.at }) {
            if let last = out.last, last.0.app == moment.app, last.0.title == moment.title {
                out[out.count - 1].1 = moment.at
                // Prefer a moment that actually has pixels behind it.
                if out[out.count - 1].0.frame == nil, moment.frame != nil {
                    out[out.count - 1].0 = moment
                }
            } else {
                out.append((moment, moment.at))
            }
        }
        return out.reversed()
    }

    /// Render recall results as the text a spoken answer can be built from.
    public static func describe(_ moments: [ScreenMoment], now: Date) -> String {
        guard !moments.isEmpty else {
            return "Nothing in the screen timeline matches that."
        }
        let lines = condense(moments).map { moment, until -> String in
            let ago = relative(from: moment.at, to: now)
            let span = until.timeIntervalSince(moment.at) >= 60
                ? " (held for \(Int(until.timeIntervalSince(moment.at) / 60)) min)" : ""
            let title = moment.title.isEmpty ? "" : " — \(moment.title)"
            return "\(ago): \(moment.app)\(title)\(span)"
        }
        return lines.joined(separator: "\n")
    }

    /// "4 min ago", "just now" — spoken-friendly, no clock arithmetic for the
    /// listener to do.
    public static func relative(from: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(from))
        if seconds < 45 { return "just now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Double(minutes) / 60
        return hours < 1.6 ? "about an hour ago" : "\(Int(hours.rounded())) hours ago"
    }
}

/// Disk-backed screen timeline: JSONL index plus JPEG frames, under
/// `~/Library/Application Support/Kweku/timeline/`.
///
/// Local only, and pruned on every write so it cannot grow without bound while
/// nobody is looking.
public final class ScreenTimelineStore {
    private let dir: URL
    private let indexFile: URL
    private let lock = NSLock()
    private var moments: [ScreenMoment] = []
    private var lastFrameWrite = Date.distantPast

    /// How often a moment is allowed to carry pixels. Titles are cheap; frames
    /// are ~100KB each, so they are sampled far more slowly than the timeline.
    private let frameInterval: TimeInterval

    public init(directory: URL? = nil, frameInterval: TimeInterval = 20) {
        self.frameInterval = frameInterval
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kweku/timeline", isDirectory: true)
        dir = base
        indexFile = base.appendingPathComponent("index.jsonl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        load()
    }

    public var latest: ScreenMoment? {
        lock.lock(); defer { lock.unlock() }
        return moments.last
    }

    /// Record what is on screen now. `jpeg` is stored only when the frame
    /// sampling interval has elapsed and the window isn't redacted.
    public func record(app: String, title: String, jpeg: Data?, redacted: Bool,
                       now: Date = Date()) {
        let (app, title) = redacted
            ? (ScreenMoment.privateLabel, "") : (app, title)

        lock.lock()
        let previous = moments.last
        guard ScreenTimeline.shouldRecord(previous: previous, app: app, title: title, now: now)
        else { lock.unlock(); return }

        var frameName: String?
        if !redacted, let jpeg, now.timeIntervalSince(lastFrameWrite) >= frameInterval {
            let name = "\(Int(now.timeIntervalSince1970 * 1000)).jpg"
            if (try? jpeg.write(to: dir.appendingPathComponent(name))) != nil {
                frameName = name
                lastFrameWrite = now
            }
        }
        let moment = ScreenMoment(at: now, app: app, title: title, frame: frameName)
        moments.append(moment)
        let kept = ScreenTimeline.prune(moments, now: now)
        let dropped = moments.count - kept.count
        moments = kept
        lock.unlock()

        if dropped > 0 { collectGarbage() }
        persist()
    }

    public func search(query: String, within minutes: Double?, now: Date = Date()) -> [ScreenMoment] {
        lock.lock(); defer { lock.unlock() }
        return ScreenTimeline.search(moments, query: query, within: minutes, now: now)
    }

    /// The stored pixels for a moment, if it kept any.
    public func frameData(for moment: ScreenMoment) -> Data? {
        guard let frame = moment.frame else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(frame))
    }

    public func clear() {
        lock.lock()
        moments = []
        lock.unlock()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let text = try? String(contentsOf: indexFile, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        moments = text.split(separator: "\n").compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return try? decoder.decode(ScreenMoment.self, from: data)
        }
        moments = ScreenTimeline.prune(moments, now: Date())
    }

    private func persist() {
        lock.lock()
        let snapshot = moments
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let text = snapshot.compactMap { moment -> String? in
            guard let data = try? encoder.encode(moment) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        try? text.write(to: indexFile, atomically: true, encoding: .utf8)
    }

    /// Delete frame files no surviving moment refers to.
    private func collectGarbage() {
        lock.lock()
        let live = Set(moments.compactMap(\.frame))
        lock.unlock()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for file in files where file.hasSuffix(".jpg") && !live.contains(file) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }
}
