import Foundation
import CoreGraphics
import KwekuKit

/// Pure logic behind the system-stats component: the counter differencing, the
/// labels, the sparkline normalisation, and the nook sizing registry the
/// component plugs into.
enum StatsTests {
    static func all() {
        cpuDeltas()
        derived()
        labels()
        history()
        layout()
    }

    // MARK: CPU

    static func cpuDeltas() {
        typealias Ticks = CPUTicks

        Check.run("cpu busy fraction is a delta, not a level") {
            let first = Ticks(user: 100, system: 50, idle: 850, nice: 0)
            // 100 more busy ticks, 300 more idle: a quarter busy over the
            // interval, even though cumulatively it's still mostly idle.
            let second = Ticks(user: 180, system: 70, idle: 1150, nice: 0)
            Check.eq(second.busyFraction(since: first) ?? -1, 0.25, "quarter busy")
        }
        Check.run("a fully pinned interval reads 100%") {
            let first = Ticks(user: 0, system: 0, idle: 100, nice: 0)
            let second = Ticks(user: 100, system: 0, idle: 100, nice: 0)
            Check.eq(second.busyFraction(since: first) ?? -1, 1, "all busy")
        }
        Check.run("nice time counts as busy") {
            let first = Ticks(user: 0, system: 0, idle: 0, nice: 0)
            let second = Ticks(user: 0, system: 0, idle: 50, nice: 50)
            Check.eq(second.busyFraction(since: first) ?? -1, 0.5, "renice'd work is still work")
        }
        Check.run("a stalled or rewound counter yields nothing") {
            let ticks = Ticks(user: 100, system: 50, idle: 850, nice: 0)
            Check.ok(ticks.busyFraction(since: ticks) == nil, "no movement, no reading")
            // Sleep/wake can walk the counters backwards; that must not be
            // reported as a sudden idle machine.
            let rewound = Ticks(user: 10, system: 5, idle: 85, nice: 0)
            Check.ok(rewound.busyFraction(since: ticks) == nil, "backwards is not 0%")
        }
    }

    // MARK: Snapshot

    static func derived() {
        Check.run("disk used is the complement of free") {
            var snap = StatsSnapshot()
            snap.diskTotalBytes = 1_000
            snap.diskFreeBytes = 250
            Check.eq(snap.diskUsedFraction, 0.75, "three quarters used")
        }
        Check.run("an unknown volume size doesn't divide by zero") {
            var snap = StatsSnapshot()
            snap.diskTotalBytes = 0
            snap.diskFreeBytes = 0
            Check.eq(snap.diskUsedFraction, 0, "no capacity, no fraction")
        }
        Check.run("load is scaled by core count and capped") {
            var snap = StatsSnapshot()
            snap.coreCount = 8
            snap.loadAverage = 4
            Check.eq(snap.loadFraction, 0.5, "half the cores' worth of runnable work")
            snap.loadAverage = 40
            Check.eq(snap.loadFraction, 1, "a thundering herd still reads as full")
        }
        Check.run("strain thresholds latch where the meters change colour") {
            var snap = StatsSnapshot()
            snap.cpuFraction = StatsSnapshot.busyCPUFraction - 0.01
            Check.ok(!snap.cpuBusy, "just under is calm")
            snap.cpuFraction = StatsSnapshot.busyCPUFraction
            Check.ok(snap.cpuBusy, "at the threshold is busy")
            snap.memoryFraction = 0.9
            Check.ok(snap.memoryTight, "0.9 of RAM is tight")
        }
    }

    // MARK: Labels

    static func labels() {
        Check.run("percent rounds to whole numbers and clamps") {
            Check.ok(StatsSnapshot.percent(0.374) == "37%", "rounds down")
            Check.ok(StatsSnapshot.percent(0.376) == "38%", "rounds up")
            Check.ok(StatsSnapshot.percent(0) == "0%", "floor")
            Check.ok(StatsSnapshot.percent(1) == "100%", "ceiling")
            Check.ok(StatsSnapshot.percent(1.4) == "100%", "clamps over")
            Check.ok(StatsSnapshot.percent(-0.2) == "0%", "clamps under")
        }
        Check.run("throughput picks a unit and stays short") {
            Check.ok(StatsSnapshot.rate(0) == "0", "idle")
            Check.ok(StatsSnapshot.rate(400) == "0", "sub-kilobyte is noise")
            Check.ok(StatsSnapshot.rate(812_000) == "812 K", "kilobytes")
            Check.ok(StatsSnapshot.rate(1_400_000) == "1.4 M", "one decimal under 10")
            Check.ok(StatsSnapshot.rate(24_000_000) == "24 M", "no decimal over 10")
            Check.ok(StatsSnapshot.rate(-5) == "0", "a negative delta is not traffic")
        }
        Check.run("byte counts get a human unit") {
            Check.ok(StatsSnapshot.bytes(512) == "512 B", "bytes")
            Check.ok(StatsSnapshot.bytes(9_400_000_000) == "9.4 GB", "one decimal under 10")
            Check.ok(StatsSnapshot.bytes(512_000_000_000) == "512 GB", "no decimal over 10")
            Check.ok(StatsSnapshot.bytes(2_000_000_000_000) == "2.0 TB", "terabytes")
            Check.ok(StatsSnapshot.bytes(-1) == "0 B", "never negative")
        }
        Check.run("memory subtitle reads as used-of-total") {
            Check.ok(StatsSnapshot.fraction(used: 9_400_000_000, total: 16_000_000_000)
                     == "9.4 GB / 16 GB", "used / total")
        }
    }

    // MARK: History

    static func history() {
        Check.run("history is a ring that drops the oldest") {
            var h = StatsHistory(capacity: 3)
            for v in [0.1, 0.2, 0.3, 0.4] { h.push(v) }
            Check.ok(h.samples.count == 3, "capped at capacity")
            Check.eq(h.samples.first ?? -1, 0.2, "oldest dropped")
            Check.eq(h.latest, 0.4, "newest kept")
        }
        Check.run("samples are clamped on the way in") {
            var h = StatsHistory(capacity: 4)
            h.push(-3); h.push(9)
            Check.eq(h.samples[0], 0, "under clamps")
            Check.eq(h.samples[1], 1, "over clamps")
        }
        Check.run("normalisation shows shape without inventing it") {
            var wide = StatsHistory(capacity: 4)
            for v in [0.0, 0.5, 1.0] { wide.push(v) }
            let scaled = wide.normalized()
            Check.eq(scaled.first ?? -1, 0, "min at the floor")
            Check.eq(scaled.last ?? -1, 1, "max at the ceiling")

            // A dead-flat trace must stay flat: dividing by its own zero span
            // would turn rounding noise into a mountain range.
            var flat = StatsHistory(capacity: 4)
            for _ in 0..<4 { flat.push(0.4) }
            Check.ok(flat.normalized().allSatisfy { $0 == 0 }, "flat stays flat")

            // A tiny wobble is scaled against the minimum span, not its own,
            // so 3%-vs-4% CPU doesn't render as a full-scale swing.
            var wobble = StatsHistory(capacity: 4)
            wobble.push(0.03); wobble.push(0.04)
            Check.ok((wobble.normalized().max() ?? 1) < 0.5, "a 1% wobble stays near the floor")
        }
    }

    // MARK: Nook registry

    static func layout() {
        let base = CGSize(width: 200, height: 32)
        // Components are internal views; the registry is how the shell — and
        // therefore this test — asks them how big they want to be.
        let statsMetrics = NookMode.stats.metrics(NookContext())
        let critterMetrics = NookMode.critter.metrics(NookContext())

        Check.run("every component declares usable metrics") {
            for mode in NookMode.allCases {
                let m = mode.metrics(NookContext(agentCount: 2))
                Check.ok(m.peek > 0, "\(mode.rawValue) has a peek band")
                Check.ok(m.expandedBody >= m.peek, "\(mode.rawValue) doesn't shrink on hover")
                Check.ok(!mode.title.isEmpty, "\(mode.rawValue) has a menu title")
            }
        }
        Check.run("closed size is the cutout plus the peek band") {
            let size = NookLayout.size(base: base, mode: .stats, open: false,
                                       context: NookContext(), strips: [])
            Check.eq(size.width, base.width, "closed never widens")
            Check.eq(size.height, base.height + statsMetrics.peek, "cutout + peek")
        }
        Check.run("open size takes the component's minimum width") {
            let size = NookLayout.size(base: base, mode: .stats, open: true,
                                       context: NookContext(), strips: [])
            Check.eq(size.width, statsMetrics.expandedWidth, "widens to the panel")
            Check.eq(size.height, base.height + statsMetrics.expandedBody, "cutout + body")
        }
        Check.run("a component narrower than the notch never shrinks it") {
            let wide = CGSize(width: 900, height: 32)
            let size = NookLayout.size(base: wide, mode: .stats, open: true,
                                       context: NookContext(), strips: [])
            Check.eq(size.width, 900, "the notch is the floor")
        }
        Check.run("strips stack in height and take the widest minimum") {
            let strips = [NookLayout.Strip(height: 40, minWidth: 260),
                          NookLayout.Strip(height: 20, minWidth: 500)]
            let size = NookLayout.size(base: base, mode: .critter, open: true,
                                       context: NookContext(), strips: strips)
            Check.eq(size.width, 500, "widest strip wins")
            Check.eq(size.height, base.height + critterMetrics.expandedBody + 60, "heights add up")
        }
        Check.run("agents mode grows a row per session") {
            func height(_ count: Int) -> CGFloat {
                NookLayout.size(base: base, mode: .agents, open: true,
                                context: NookContext(agentCount: count), strips: []).height
            }
            Check.ok(height(4) > height(1), "more sessions, taller panel")
            Check.ok(height(50) == height(20), "and it caps")
        }
        Check.run("cycling wraps in both directions and covers every mode") {
            var seen: Set<NookMode> = []
            var mode = NookMode.critter
            for _ in NookMode.allCases.indices {
                seen.insert(mode)
                mode = mode.advanced(by: 1)
            }
            Check.ok(seen.count == NookMode.allCases.count, "a full turn visits all of them")
            Check.ok(mode == .critter, "and comes home")
            Check.ok(NookMode.critter.advanced(by: -1) == NookMode.allCases.last,
                     "scrolling back wraps to the end")
        }
    }
}
