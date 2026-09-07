import Foundation

/// What one agent turn spent.
///
/// Cache writes are split by TTL because they are priced differently — a
/// one-hour write costs twice base input, a five-minute one 1.25× — and a
/// coding agent's bill is mostly cache traffic, so collapsing them would put
/// the total out by more than the plain tokens are worth.
public struct BurnUsage: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    /// The cost the harness worked out for itself. omp records one per turn;
    /// Claude Code records only tokens, and those get priced here.
    public var dollars: Double?

    public init(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0,
                cacheWrite1h: Int = 0, cacheRead: Int = 0, dollars: Double? = nil) {
        self.input = input; self.output = output
        self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead; self.dollars = dollars
    }

    public var tokens: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
}

/// List prices, in dollars per million tokens.
///
/// A table of published rates, not a bill: a subscription or a discount makes
/// the real number lower. It's here to answer "which agent is eating the day",
/// which is a question about proportion, and proportion survives the caveat.
public enum ModelPrice {

    /// Plain input and output rates for a model id, or nil when it isn't one
    /// this knows — an unknown model still contributes tokens, just no dollars,
    /// which is the honest way to be wrong about it.
    public static func rates(for model: String) -> (input: Double, output: Double)? {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return (10, 50) }
        if m.contains("opus") { return (5, 25) }
        // Sonnet's price moved between generations; everything before 5 was $3.
        if m.contains("sonnet") { return m.contains("sonnet-5") ? (2, 10) : (3, 15) }
        if m.contains("haiku") { return (1, 5) }
        return nil
    }

    /// Cache reads are a tenth of base input everywhere except Fable 5.1 /
    /// Mythos 5.1, which read at a quarter of that again.
    static func cacheReadRate(_ model: String) -> Double {
        let m = model.lowercased()
        return (m.contains("fable-5-1") || m.contains("mythos-5-1")) ? 0.025 : 0.1
    }

    /// What a turn cost. A harness-reported figure always wins: it knows which
    /// deal it was billed under, and this table is only a list price.
    public static func dollars(_ usage: BurnUsage, model: String) -> Double {
        if let reported = usage.dollars { return reported }
        guard let rate = rates(for: model) else { return 0 }
        let input = rate.input / 1_000_000
        return input * Double(usage.input)
            + rate.output / 1_000_000 * Double(usage.output)
            + input * 1.25 * Double(usage.cacheWrite5m)
            + input * 2 * Double(usage.cacheWrite1h)
            + input * cacheReadRate(model) * Double(usage.cacheRead)
    }
}

/// One priced turn read out of a transcript.
public struct BurnEntry: Equatable, Sendable {
    public var at: Date
    /// The repo the turn ran in, already shortened for display. Empty when the
    /// line didn't say, and the scanner falls back to the folder name.
    public var project: String
    public var model: String
    public var usage: BurnUsage

    public var dollars: Double { ModelPrice.dollars(usage, model: model) }
}

/// The day's spend, and the shape the panel draws.
public struct BurnTotals: Equatable, Sendable {
    public struct Project: Equatable, Sendable {
        public var name: String
        public var dollars: Double
        public var tokens: Int

        public init(name: String, dollars: Double, tokens: Int) {
            self.name = name; self.dollars = dollars; self.tokens = tokens
        }
    }

    public var dollars: Double = 0
    public var tokens: Int = 0
    /// Most expensive first — the point of the meter is which one is eating it.
    public var byProject: [Project] = []

    public init(dollars: Double = 0, tokens: Int = 0, byProject: [Project] = []) {
        self.dollars = dollars; self.tokens = tokens; self.byProject = byProject
    }

    // MARK: Formatting

    /// "$0", "$0.42", "$12.40", "$340". Cents stop mattering somewhere around
    /// the point where the number is the reason you're looking.
    public static func money(_ dollars: Double) -> String {
        let value = max(0, dollars)
        if value < 0.005 { return "$0" }
        if value < 100 { return String(format: "$%.2f", value) }
        return "$\(Int(value.rounded()))"
    }

    /// "820", "12k", "3.2M" — the sparklines' neighbour, so it has to stay
    /// short enough not to push the row around.
    public static func tokens(_ count: Int) -> String {
        let value = Double(max(0, count))
        if value < 1_000 { return "\(Int(value))" }
        if value < 1_000_000 { return "\(Int((value / 1_000).rounded()))k" }
        let millions = value / 1_000_000
        return millions < 10 ? String(format: "%.1fM", millions) : "\(Int(millions.rounded()))M"
    }

    /// "sidekick $7.10 · notch $3.90" — where the money actually went.
    public func breakdown(limit: Int = 3) -> String {
        byProject.prefix(limit)
            .map { "\($0.name) \(Self.money($0.dollars))" }
            .joined(separator: " · ")
    }
}

/// Today's agent spend, read off the harnesses' own transcripts.
///
/// No new bookkeeping and nothing to install: omp and Claude Code both already
/// write one JSON line per turn with the usage on it, so the meter is a reader,
/// not a recorder — and it can't drift from what actually happened.
///
/// Held across refreshes because transcripts are append-only: each pass reads
/// from where the last one stopped, so a day of 200 MB of session logs costs
/// one full read and then only the new bytes.
public final class BurnMeter: @unchecked Sendable {

    /// What's been counted in one transcript so far.
    private struct FileState {
        var offset: UInt64
        var project: String
        var dollars: Double
        var tokens: Int
    }

    private var files: [String: FileState] = [:]
    private var day: Date?
    private let roots: [URL]

    public init(roots: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [home.appendingPathComponent(".claude/projects"),
                               home.appendingPathComponent(".omp/agent/sessions")]
    }

    /// Re-read whatever the agents have appended since the last call.
    public func refresh(now: Date = Date(), calendar: Calendar = .current) -> BurnTotals {
        let start = calendar.startOfDay(for: now)
        if day != start {
            files.removeAll()   // a new day starts from zero, not from yesterday
            day = start
        }
        for root in roots { scan(root, since: start) }
        return totals()
    }

    // MARK: - Reading

    private func scan(_ root: URL, since: Date) {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for project in projects {
            guard let transcripts = try? manager.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in transcripts where file.pathExtension == "jsonl" {
                // Yesterday's sessions are not today's spend, and there are a
                // lot of them — skipping on mtime is what keeps this cheap.
                let touched = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let touched, touched >= since else { continue }
                ingest(file, since: since)
            }
        }
    }

    private func ingest(_ url: URL, since: Date) {
        let key = url.path
        var state = files[key] ?? FileState(
            offset: 0,
            project: Self.projectName(fromDirectory: url.deletingLastPathComponent().lastPathComponent),
            dollars: 0, tokens: 0)

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // A file that shrank was rotated or replaced; anything counted from it
        // belonged to a transcript that no longer exists.
        if size < state.offset { state = FileState(offset: 0, project: state.project, dollars: 0, tokens: 0) }
        guard size > state.offset else { files[key] = state; return }

        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.read(upToCount: Int(size - state.offset)),
              let end = data.lastIndex(of: 0x0A)
        else { files[key] = state; return }

        // Only whole lines: the agent is still writing to this file, and half a
        // JSON object counted now would be counted again when it completes.
        state.offset += UInt64(end - data.startIndex + 1)
        for line in data[..<end].split(separator: 0x0A) {
            guard let text = String(data: Data(line), encoding: .utf8),
                  let entry = Self.parse(line: text),
                  entry.at >= since else { continue }
            if !entry.project.isEmpty { state.project = entry.project }
            state.dollars += entry.dollars
            state.tokens += entry.usage.tokens
        }
        files[key] = state
    }

    private func totals() -> BurnTotals {
        var byProject: [String: BurnTotals.Project] = [:]
        var dollars = 0.0
        var tokens = 0
        for state in files.values where state.tokens > 0 {
            var project = byProject[state.project]
                ?? BurnTotals.Project(name: state.project, dollars: 0, tokens: 0)
            project.dollars += state.dollars
            project.tokens += state.tokens
            byProject[state.project] = project
            dollars += state.dollars
            tokens += state.tokens
        }
        return BurnTotals(dollars: dollars, tokens: tokens,
                          byProject: byProject.values.sorted {
                              $0.dollars != $1.dollars ? $0.dollars > $1.dollars : $0.name < $1.name
                          })
    }

    // MARK: - Pure parsing

    /// `-Users-omarinyarko-Desktop-sidekick` -> `sidekick`. Both harnesses
    /// encode the working directory into the transcript folder's name the same
    /// way, and the tail is the only part anyone reads.
    public static func projectName(fromDirectory encoded: String) -> String {
        let parts = encoded.split(separator: "-").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? encoded
    }

    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ raw: String) -> Date? {
        timestamps.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// One transcript line, in either harness's format. Nil for every line that
    /// isn't a billed assistant turn — which is most of them.
    public static func parse(line: String) -> BurnEntry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = (obj["timestamp"] as? String).flatMap(date),
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = (message["model"] as? String) ?? ""

        // omp: tokens under short names, and its own costing already done.
        if let total = (usage["cost"] as? [String: Any])?["total"] as? Double {
            let cache = usage["cttl"] as? [String: Any]
            let write = usage["cacheWrite"] as? Int ?? 0
            return BurnEntry(
                at: stamp, project: "", model: model,
                usage: BurnUsage(input: usage["input"] as? Int ?? 0,
                                 output: usage["output"] as? Int ?? 0,
                                 cacheWrite5m: cache?["ephemeral5m"] as? Int ?? write,
                                 cacheWrite1h: cache?["ephemeral1h"] as? Int ?? 0,
                                 cacheRead: usage["cacheRead"] as? Int ?? 0,
                                 dollars: total))
        }

        // Claude Code: the Anthropic usage block verbatim, tokens only.
        guard obj["type"] as? String == "assistant" else { return nil }
        let created = usage["cache_creation"] as? [String: Any]
        let creationTotal = usage["cache_creation_input_tokens"] as? Int ?? 0
        // No TTL split on older lines: assume the cheaper five-minute write
        // rather than inflating the day with a premium that may not have been paid.
        let write5m = created?["ephemeral_5m_input_tokens"] as? Int
            ?? (created == nil ? creationTotal : 0)
        let write1h = created?["ephemeral_1h_input_tokens"] as? Int ?? 0
        let cwd = (obj["cwd"] as? String) ?? ""

        return BurnEntry(
            at: stamp,
            project: cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent,
            model: model,
            usage: BurnUsage(input: usage["input_tokens"] as? Int ?? 0,
                             output: usage["output_tokens"] as? Int ?? 0,
                             cacheWrite5m: write5m,
                             cacheWrite1h: write1h,
                             cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0))
    }
}
