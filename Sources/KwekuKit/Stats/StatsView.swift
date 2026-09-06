import SwiftUI

/// System mode: what the machine is actually doing.
///
/// Collapsed it's CPU and memory in the band below the cutout — the two numbers
/// worth a glance. Hover-expanded it becomes four meters: CPU and memory with
/// live sparklines, then network throughput and power/disk on the line below.
///
/// Same shape-owns-its-own-background pattern as `WeatherView`, and the same
/// discipline about animation: the sparklines are `Canvas` redraws driven by
/// the 2s poll, not a `TimelineView`, so an open panel costs two frames a
/// second rather than thirty.
struct StatsView: View, NookComponent {
    @ObservedObject var stats: StatsHub
    @ObservedObject var vm: NotchViewModel
    var rim: NotchRimStyle

    static let peek: CGFloat = 30
    static let expandedBody: CGFloat = 104
    static let expandedWidth: CGFloat = 320

    static func metrics(_ context: NookContext) -> NookMetrics {
        NookMetrics(peek: peek, expandedBody: expandedBody, expandedWidth: expandedWidth)
    }

    private var expanded: Bool { vm.isHovering || vm.expanded }
    private var snapshot: StatsSnapshot { stats.snapshot }

    var body: some View {
        let cutoutH = vm.notchSize.height
        let bodyH = expanded ? Self.expandedBody : Self.peek

        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .top) {
                Color.clear
                ZStack(alignment: .top) {
                    NotchPanelShape(notchWidth: vm.notchSize.width, notchHeight: cutoutH,
                                    bottom: expanded ? 22 : 12)
                        .fill(Color.black)
                    NotchRim(notchWidth: vm.notchSize.width, notchHeight: cutoutH,
                             bottom: expanded ? 22 : 12, style: rim)
                    Group { expanded ? AnyView(expandedPanel) : AnyView(collapsedBand) }
                        .frame(width: w, height: bodyH)
                        .offset(y: cutoutH)
                }
                .frame(width: w, height: cutoutH + bodyH)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Collapsed

    private var collapsedBand: some View {
        HStack(spacing: 8) {
            Sparkline(values: stats.cpuHistory.normalized(), color: cpuColor)
                .frame(width: 26, height: 12)
            Text(StatsSnapshot.percent(snapshot.cpuFraction))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(cpuColor)
                .monospacedDigit()
            Circle().fill(Color.white.opacity(0.25)).frame(width: 2.5, height: 2.5)
            Image(systemName: "memorychip")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
            Text(StatsSnapshot.percent(snapshot.memoryFraction))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(memoryColor)
                .monospacedDigit()
        }
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                traceMeter(title: "CPU",
                           value: StatsSnapshot.percent(snapshot.cpuFraction),
                           detail: loadDetail,
                           history: stats.cpuHistory,
                           color: cpuColor)
                traceMeter(title: "Memory",
                           value: StatsSnapshot.percent(snapshot.memoryFraction),
                           detail: StatsSnapshot.fraction(used: snapshot.memoryUsedBytes,
                                                          total: snapshot.memoryTotalBytes),
                           history: stats.memoryHistory,
                           color: memoryColor)
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 0) {
                footnote(symbol: "arrow.down", text: StatsSnapshot.rate(snapshot.networkInPerSec),
                         unit: "B/s", tint: NotchRim.mint)
                footnote(symbol: "arrow.up", text: StatsSnapshot.rate(snapshot.networkOutPerSec),
                         unit: "B/s", tint: NotchRim.teal)
                powerFootnote
                footnote(symbol: "internaldrive", text: StatsSnapshot.bytes(snapshot.diskFreeBytes),
                         unit: "free", tint: .white.opacity(0.6))
            }
        }
        .padding(.horizontal, 20).padding(.top, 9).padding(.bottom, 10)
    }

    /// One labelled sparkline: title, big number, and the trace under it.
    private func traceMeter(title: String, value: String, detail: String,
                            history: StatsHistory, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            Sparkline(values: history.normalized(), color: color)
                .frame(height: 16)
            Text(detail)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Battery on a laptop, load average on a machine that hasn't got one —
    /// a permanently-100% battery meter tells a Mac mini owner nothing.
    @ViewBuilder private var powerFootnote: some View {
        if snapshot.onDesktop {
            footnote(symbol: "gauge.medium",
                     text: String(format: "%.2f", snapshot.loadAverage),
                     unit: "load", tint: .white.opacity(0.6))
        } else {
            footnote(symbol: snapshot.charging ? "bolt.fill" : "battery.100",
                     text: StatsSnapshot.percent(snapshot.batteryFraction),
                     unit: snapshot.charging ? "charging" : "battery",
                     tint: batteryColor)
        }
    }

    private func footnote(symbol: String, text: String, unit: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadDetail: String {
        "load \(String(format: "%.2f", snapshot.loadAverage)) · \(snapshot.coreCount) cores"
    }

    // MARK: - Colour

    /// Meters go amber when the machine is genuinely under strain, so the panel
    /// can be read at a glance without parsing the numbers.
    private var cpuColor: Color { snapshot.cpuBusy ? NotchRim.amber : NotchRim.teal }
    private var memoryColor: Color { snapshot.memoryTight ? NotchRim.amber : NotchRim.violet }
    private var batteryColor: Color {
        if snapshot.charging { return AgentPanelView.ready }
        return snapshot.batteryFraction < SensorSnapshot.lowBatteryFraction
            ? NotchRim.amber : .white.opacity(0.6)
    }
}

/// A filled line trace over normalised 0…1 samples.
///
/// Static `Canvas` rather than `TimelineView`: the data only changes when the
/// hub polls, and animating between polls would invent motion that isn't in the
/// measurements.
struct Sparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, size.width > 0, size.height > 0 else {
                // A single sample is a dot, not a line — draw the baseline so
                // the box doesn't read as broken while history fills up.
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height - 1))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                context.stroke(baseline, with: .color(color.opacity(0.25)), lineWidth: 1)
                return
            }

            let step = size.width / CGFloat(values.count - 1)
            // Inset so a full-scale sample isn't clipped by the stroke width.
            let top: CGFloat = 1.5
            let usable = max(1, size.height - top - 1)

            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step,
                                    y: top + usable * CGFloat(1 - value))
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.32), color.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            context.stroke(line, with: .color(color.opacity(0.95)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}
