import SwiftUI

/// Weather mode: the nook shows a Canvas-drawn scene + temperature.
/// Collapsed: mini scene + temp in the band below the cutout. Hover-expanded:
/// a larger animated scene (rain/snow/lightning move; sun/moon are calm) with
/// temperature and place. All drawing is `Canvas` — no image assets.
struct WeatherView: View {
    @ObservedObject var weather: WeatherHub
    @ObservedObject var vm: NotchViewModel
    var rim: NotchRimStyle

    static let peek: CGFloat = 30
    static let expandedBody: CGFloat = 96
    static let expandedWidth: CGFloat = 300

    private var expanded: Bool { vm.isHovering || vm.expanded }

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
        HStack(spacing: 7) {
            if let snap = weather.snapshot {
                WeatherSceneView(scene: snap.scene, animated: false)
                    .frame(width: 20, height: 20)
                Text(snap.tempText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "cloud").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Text(weather.needsCity ? "Set city…" : "—")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        HStack(spacing: 14) {
            WeatherSceneView(scene: weather.snapshot?.scene ?? .cloudy, animated: true)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(weather.snapshot?.tempText ?? "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(label(for: weather.snapshot?.scene))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                if let place = weather.snapshot?.place {
                    Text(place).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }

    private func label(for scene: WeatherScene?) -> String {
        switch scene {
        case .clearDay: return "Sunny"
        case .clearNight: return "Clear"
        case .partlyDay, .partlyNight: return "Partly cloudy"
        case .cloudy: return "Overcast"
        case .fog: return "Fog"
        case .rain: return "Rain"
        case .snow: return "Snow"
        case .thunder: return "Thunderstorm"
        case nil: return weather.needsCity ? "Right-click → Set City…" : "Loading…"
        }
    }
}

/// One weather scene drawn in Canvas. `animated` uses TimelineView — only used
/// while the panel is expanded, so idle CPU stays flat.
struct WeatherSceneView: View {
    var scene: WeatherScene
    var animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                Canvas { ctx, size in
                    Self.draw(scene, in: ctx, size: size,
                              t: context.date.timeIntervalSinceReferenceDate)
                }
            }
        } else {
            Canvas { ctx, size in Self.draw(scene, in: ctx, size: size, t: 0) }
        }
    }

    // MARK: - Drawing

    static func draw(_ scene: WeatherScene, in ctx: GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        switch scene {
        case .clearDay:
            sun(ctx, center: CGPoint(x: w/2, y: h/2), r: w*0.22, t: t)
        case .clearNight:
            moon(ctx, center: CGPoint(x: w/2, y: h/2), r: w*0.22)
            stars(ctx, size: size, t: t)
        case .partlyDay:
            sun(ctx, center: CGPoint(x: w*0.38, y: h*0.38), r: w*0.16, t: t)
            cloud(ctx, center: CGPoint(x: w*0.58, y: h*0.6), scale: w*0.30, shade: 0.85)
        case .partlyNight:
            moon(ctx, center: CGPoint(x: w*0.38, y: h*0.38), r: w*0.15)
            cloud(ctx, center: CGPoint(x: w*0.58, y: h*0.6), scale: w*0.30, shade: 0.7)
        case .cloudy:
            cloud(ctx, center: CGPoint(x: w*0.42, y: h*0.42), scale: w*0.30, shade: 0.6)
            cloud(ctx, center: CGPoint(x: w*0.6, y: h*0.6), scale: w*0.34, shade: 0.8)
        case .fog:
            for i in 0..<4 {
                let y = h * (0.3 + 0.15 * Double(i))
                var p = Path()
                p.move(to: CGPoint(x: w*0.15, y: y)); p.addLine(to: CGPoint(x: w*0.85, y: y))
                ctx.stroke(p, with: .color(.white.opacity(0.55 - 0.08*Double(i))),
                           style: StrokeStyle(lineWidth: w*0.06, lineCap: .round))
            }
        case .rain:
            cloud(ctx, center: CGPoint(x: w/2, y: h*0.36), scale: w*0.34, shade: 0.75)
            drops(ctx, size: size, t: t, count: 7, speed: 1.6, len: h*0.14,
                  color: Color(red: 0.55, green: 0.75, blue: 1.0))
        case .snow:
            cloud(ctx, center: CGPoint(x: w/2, y: h*0.36), scale: w*0.34, shade: 0.85)
            flakes(ctx, size: size, t: t)
        case .thunder:
            cloud(ctx, center: CGPoint(x: w/2, y: h*0.36), scale: w*0.36, shade: 0.45)
            drops(ctx, size: size, t: t, count: 5, speed: 2.0, len: h*0.12,
                  color: Color(red: 0.55, green: 0.7, blue: 0.95))
            let phase = t.truncatingRemainder(dividingBy: 2.6)
            if t == 0 || phase < 0.18 {
                bolt(ctx, size: size, alpha: t == 0 ? 1 : 1 - phase / 0.18)
            }
        }
    }

    private static func sun(_ ctx: GraphicsContext, center: CGPoint, r: CGFloat, t: Double) {
        let amber = Color(red: 1.0, green: 0.75, blue: 0.25)
        let spin = t * 0.15
        for i in 0..<8 {
            let a = Double(i) * .pi / 4 + spin
            var p = Path()
            p.move(to: CGPoint(x: center.x + cos(a) * r * 1.35, y: center.y + sin(a) * r * 1.35))
            p.addLine(to: CGPoint(x: center.x + cos(a) * r * 1.75, y: center.y + sin(a) * r * 1.75))
            ctx.stroke(p, with: .color(amber.opacity(0.9)),
                       style: StrokeStyle(lineWidth: r * 0.18, lineCap: .round))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r*2, height: r*2)),
                 with: .color(amber))
    }

    private static func moon(_ ctx: GraphicsContext, center: CGPoint, r: CGFloat) {
        // Crescent via black overlay (panel is black) — Path.subtracting is 14+.
        let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r*2, height: r*2))
        let bite = Path(ellipseIn: CGRect(x: center.x - r*0.35, y: center.y - r*1.15, width: r*2, height: r*2))
        ctx.fill(disc, with: .color(.white.opacity(0.92)))
        ctx.fill(bite, with: .color(.black))
    }

    private static func stars(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let pts: [(CGFloat, CGFloat)] = [(0.2, 0.25), (0.8, 0.2), (0.75, 0.7), (0.18, 0.72), (0.62, 0.35)]
        for (i, p) in pts.enumerated() {
            let twinkle = t == 0 ? 0.8 : 0.5 + 0.5 * abs(sin(t * 1.3 + Double(i) * 1.7))
            ctx.fill(Path(ellipseIn: CGRect(x: p.0 * size.width, y: p.1 * size.height, width: 2, height: 2)),
                     with: .color(.white.opacity(0.9 * twinkle)))
        }
    }

    private static func cloud(_ ctx: GraphicsContext, center: CGPoint, scale s: CGFloat, shade: CGFloat) {
        var p = Path()
        p.addEllipse(in: CGRect(x: center.x - s, y: center.y - s*0.35, width: s*0.9, height: s*0.7))
        p.addEllipse(in: CGRect(x: center.x - s*0.45, y: center.y - s*0.65, width: s*1.05, height: s*1.0))
        p.addEllipse(in: CGRect(x: center.x + 0.05*s, y: center.y - s*0.4, width: s*0.95, height: s*0.75))
        ctx.fill(p, with: .color(.white.opacity(shade)))
    }

    private static func drops(_ ctx: GraphicsContext, size: CGSize, t: Double, count: Int,
                              speed: Double, len: CGFloat, color: Color) {
        let region = CGRect(x: size.width*0.22, y: size.height*0.52,
                            width: size.width*0.56, height: size.height*0.42)
        for i in 0..<count {
            let fx = CGFloat(i * 37 % 100) / 100
            let phase = Double(i * 61 % 100) / 100
            let fy = t == 0 ? phase : (t * speed + phase).truncatingRemainder(dividingBy: 1)
            let x = region.minX + fx * region.width
            let y = region.minY + CGFloat(fy) * region.height
            var p = Path()
            p.move(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x - len*0.15, y: y + len))
            ctx.stroke(p, with: .color(color.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }

    private static func flakes(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let region = CGRect(x: size.width*0.22, y: size.height*0.5,
                            width: size.width*0.56, height: size.height*0.45)
        for i in 0..<7 {
            let fx = CGFloat(i * 41 % 100) / 100
            let phase = Double(i * 53 % 100) / 100
            let fy = t == 0 ? phase : (t * 0.35 + phase).truncatingRemainder(dividingBy: 1)
            let sway = t == 0 ? 0 : sin(t * 2 + Double(i)) * 2
            ctx.fill(Path(ellipseIn: CGRect(x: region.minX + fx*region.width + sway,
                                            y: region.minY + CGFloat(fy)*region.height,
                                            width: 3, height: 3)),
                     with: .color(.white.opacity(0.95)))
        }
    }

    private static func bolt(_ ctx: GraphicsContext, size: CGSize, alpha: Double) {
        let w = size.width, h = size.height
        var p = Path()
        p.move(to: CGPoint(x: w*0.52, y: h*0.45))
        p.addLine(to: CGPoint(x: w*0.42, y: h*0.66))
        p.addLine(to: CGPoint(x: w*0.5, y: h*0.66))
        p.addLine(to: CGPoint(x: w*0.4, y: h*0.9))
        p.addLine(to: CGPoint(x: w*0.58, y: h*0.62))
        p.addLine(to: CGPoint(x: w*0.5, y: h*0.62))
        p.addLine(to: CGPoint(x: w*0.6, y: h*0.45))
        p.closeSubpath()
        ctx.fill(p, with: .color(Color(red: 1.0, green: 0.9, blue: 0.4).opacity(alpha)))
    }
}
