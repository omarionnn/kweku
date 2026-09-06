import Foundation

/// Cumulative CPU ticks since boot, summed over all cores.
///
/// The kernel only reports totals, so a percentage is always a difference
/// between two readings. That differencing is the fiddly part — it has to
/// survive counters that stall, wrap, or walk backwards across a sleep — so it
/// lives here in the pure layer rather than next to the `host_statistics` call.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }

    /// Renice'd work is still work.
    public var busy: UInt64 { user &+ system &+ nice }
    public var total: UInt64 { busy &+ idle }

    /// Busy fraction over the interval between two readings. Nil when the
    /// counters didn't move, or moved backwards — which they do across a
    /// sleep/wake — so the caller holds its last good value instead of drawing
    /// a machine that suddenly went idle.
    public func busyFraction(since previous: CPUTicks) -> Double? {
        guard total >= previous.total, busy >= previous.busy else { return nil }
        let elapsed = total - previous.total
        guard elapsed > 0 else { return nil }
        return min(1, Double(busy - previous.busy) / Double(elapsed))
    }
}

/// A point-in-time reading of the machine's load, and the pure formatting the
/// stats panel draws from it. Kept free of AppKit so every label and threshold
/// in the component is unit-testable.
public struct StatsSnapshot: Equatable, Sendable {
    /// 0…1 busy across all cores.
    public var cpuFraction: Double = 0
    /// 0…1 of installed RAM in use (app + wired + compressed).
    public var memoryFraction: Double = 0
    public var memoryUsedBytes: UInt64 = 0
    public var memoryTotalBytes: UInt64 = 0
    /// Bytes per second over the last poll interval.
    public var networkInPerSec: Double = 0
    public var networkOutPerSec: Double = 0
    public var diskFreeBytes: Int64 = 0
    public var diskTotalBytes: Int64 = 0
    public var batteryFraction: Double = 1
    public var charging: Bool = false
    /// True when the machine has no battery — the panel shows disk instead.
    public var onDesktop: Bool = false
    /// One-minute load average.
    public var loadAverage: Double = 0
    public var coreCount: Int = 1

    public init() {}

    // MARK: Derived

    /// 0…1 of the boot volume in use.
    public var diskUsedFraction: Double {
        guard diskTotalBytes > 0 else { return 0 }
        let used = Double(diskTotalBytes - diskFreeBytes)
        return min(1, max(0, used / Double(diskTotalBytes)))
    }

    /// Load relative to the core count — 1.0 means "every core has a runnable
    /// thread waiting", which is the point the number starts meaning something.
    public var loadFraction: Double {
        guard coreCount > 0 else { return 0 }
        return min(1, loadAverage / Double(coreCount))
    }

    // MARK: Thresholds

    /// Above this the CPU meter goes amber — sustained work, not a spike.
    public static let busyCPUFraction: Double = 0.70
    /// Above this the memory meter goes amber: swapping is close.
    public static let tightMemoryFraction: Double = 0.85

    public var cpuBusy: Bool { cpuFraction >= Self.busyCPUFraction }
    public var memoryTight: Bool { memoryFraction >= Self.tightMemoryFraction }

    // MARK: Formatting

    /// "37%" — whole numbers only; a decimal point on a 4-point-wide meter is
    /// noise, and the sparkline already carries the shape.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// Compact throughput: "0", "812 K", "1.4 M". Unit-suffixed per second by
    /// the caller's label, so the number stays short enough for the band.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1_000 { return "0" }
        if value < 1_000_000 { return "\(Int((value / 1_000).rounded())) K" }
        let megs = value / 1_000_000
        return megs < 10 ? String(format: "%.1f M", megs) : "\(Int(megs.rounded())) M"
    }

    /// "9.4 GB" / "512 GB" — one decimal below 10 so small numbers keep their
    /// resolution and large ones don't get noisy.
    public static func bytes(_ count: Int64) -> String {
        let units: [(Double, String)] = [(1_000_000_000_000, "TB"), (1_000_000_000, "GB"),
                                         (1_000_000, "MB"), (1_000, "KB")]
        let value = Double(max(0, count))
        for (scale, suffix) in units where value >= scale {
            let scaled = value / scale
            return scaled < 10 ? String(format: "%.1f %@", scaled, suffix)
                               : "\(Int(scaled.rounded())) \(suffix)"
        }
        return "\(Int(value)) B"
    }

    /// "9.4 / 16 GB" for the memory meter's subtitle.
    public static func fraction(used: UInt64, total: UInt64) -> String {
        "\(bytes(Int64(used))) / \(bytes(Int64(total)))"
    }
}

/// A fixed-length ring of recent samples, for the sparklines.
///
/// Holds raw 0…1 values and normalises on read: a CPU trace that never leaves
/// 3% should still show its shape, but a flat line must stay flat rather than
/// exploding into noise, so the span is floored before dividing.
public struct StatsHistory: Equatable, Sendable {
    public private(set) var samples: [Double]
    public let capacity: Int

    /// Smallest range a trace is scaled against. Below this the line is drawn
    /// near the floor instead of being stretched to fill the box.
    public static let minimumSpan: Double = 0.12

    public init(capacity: Int = 48) {
        self.capacity = max(2, capacity)
        self.samples = []
    }

    public mutating func push(_ value: Double) {
        samples.append(min(1, max(0, value)))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public var latest: Double { samples.last ?? 0 }

    /// Samples mapped to 0…1 of the drawing box.
    public func normalized() -> [Double] {
        guard let low = samples.min(), let high = samples.max() else { return [] }
        let span = max(high - low, Self.minimumSpan)
        return samples.map { min(1, max(0, ($0 - low) / span)) }
    }
}
