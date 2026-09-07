import Foundation
import Combine

/// Owns the machine-load polling and the sparkline history.
///
/// Polls only while the stats mode is showing — same `setActive` contract as
/// `WeatherHub`, for the same reason: a notch component that samples the kernel
/// twice a second when nobody is looking at it is a battery bug, not a feature.
@MainActor
public final class StatsHub: ObservableObject {
    @Published public private(set) var snapshot = StatsSnapshot()
    @Published public private(set) var cpuHistory = StatsHistory()
    @Published public private(set) var memoryHistory = StatsHistory()
    @Published public private(set) var networkHistory = StatsHistory()
    /// What the coding agents have spent today. The machine's other load.
    @Published public private(set) var burn = BurnTotals()

    /// Fast enough to feel live, slow enough to stay invisible in Activity
    /// Monitor. The rates are per-interval deltas, so this also sets their
    /// resolution.
    private static let interval: TimeInterval = 2

    /// Polls between burn re-reads. Spend moves in turns, not in seconds, and
    /// each pass touches the filesystem — 30s is far more resolution than a
    /// running total deserves.
    private static let burnEvery = 15

    /// Ceiling the network sparkline is scaled against, so a 20 MB/s burst and
    /// a 2 KB/s trickle don't render identically. Bytes per second.
    private static let networkScale: Double = 5_000_000

    private var timer: Timer?
    private var active = false
    private var lastTicks: CPUTicks?
    private var lastNetwork: (received: UInt64, sent: UInt64)?
    private var lastNetworkAt: Date?
    private let meter = BurnMeter()
    private var burnCountdown = 0
    /// One scan at a time: the meter carries per-file read offsets, and two
    /// overlapping passes would each advance them past the other's lines.
    private var burnBusy = false

    public init() {}

    deinit { timer?.invalidate() }

    /// Enable/disable polling. Enabling takes a priming read immediately so the
    /// panel has numbers before the first tick, though rates stay at zero until
    /// there are two samples to subtract.
    public func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        timer?.invalidate(); timer = nil
        guard on else { return }

        burnCountdown = 0
        poll()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = Self.interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        var next = snapshot
        let now = Date()

        burnCountdown -= 1
        if burnCountdown <= 0 {
            burnCountdown = Self.burnEvery
            refreshBurn()
        }

        // CPU: ticks are cumulative, so the first poll after enabling only
        // establishes a baseline. Hold the previous value rather than showing
        // a fake 0% for one frame.
        if let ticks = SystemMetrics.cpuTicks() {
            if let previous = lastTicks, let busy = ticks.busyFraction(since: previous) {
                next.cpuFraction = busy
            }
            lastTicks = ticks
        }

        if let memory = SystemMetrics.memory() {
            next.memoryUsedBytes = memory.used
            next.memoryTotalBytes = memory.total
            next.memoryFraction = Double(memory.used) / Double(memory.total)
        }

        let network = SystemMetrics.networkBytes()
        if let previous = lastNetwork, let at = lastNetworkAt {
            let seconds = max(0.1, now.timeIntervalSince(at))
            // Counters reset when an interface goes away (VPN up/down, dock
            // unplugged); a negative delta means "started over", not traffic.
            let inDelta = network.received >= previous.received ? network.received - previous.received : 0
            let outDelta = network.sent >= previous.sent ? network.sent - previous.sent : 0
            next.networkInPerSec = Double(inDelta) / seconds
            next.networkOutPerSec = Double(outDelta) / seconds
        }
        lastNetwork = network
        lastNetworkAt = now

        let power = SystemSensors.power()
        next.charging = power.charging
        next.batteryFraction = power.fraction
        next.diskFreeBytes = SystemSensors.diskFreeBytes()
        next.diskTotalBytes = SystemMetrics.diskTotalBytes()
        next.loadAverage = SystemMetrics.loadAverage()
        next.coreCount = SystemMetrics.coreCount
        next.onDesktop = SystemSensors.hasBattery() == false

        if next != snapshot { snapshot = next }

        cpuHistory.push(next.cpuFraction)
        memoryHistory.push(next.memoryFraction)
        networkHistory.push(min(1, (next.networkInPerSec + next.networkOutPerSec) / Self.networkScale))
    }

    /// Re-read the transcripts off the main thread — the first pass of the day
    /// walks every session file the agents have written since midnight.
    private func refreshBurn() {
        guard !burnBusy else { return }
        burnBusy = true
        let meter = self.meter
        Task.detached(priority: .utility) { [weak self] in
            let totals = meter.refresh()
            await self?.apply(burn: totals)
        }
    }

    private func apply(burn totals: BurnTotals) {
        burnBusy = false
        if totals != burn { burn = totals }
    }
}
