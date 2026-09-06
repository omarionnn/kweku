import SwiftUI

/// What the rim is saying. One style at a time, highest urgency wins — see
/// `NotchRimStyle.resolve`.
public enum NotchRimStyle: Equatable {
    /// Nothing to report; the rim isn't drawn at all.
    case none
    /// A Kweku Live session is open. Breathing gradient, brighter while Kweku
    /// speaks (`level` is the 0…1 speech amplitude).
    case live(level: CGFloat)
    /// At least one agent session has the floor. The *activity* picks the
    /// temperament — a slow violet aurora while it reasons, a warm comet
    /// while a tool runs, a left-to-right tide while it answers — so a
    /// glance tells you not just that Kweku is busy but how.
    case working(activity: AgentActivity)
    /// A session just flipped to *waiting*: the whole rim pulses amber.
    case attention
    /// Music is playing and the cover has a colour worth wearing. The lowest
    /// priority signal there is — purely ambient, never competing with a state
    /// you need to act on. Resolved by the music island itself rather than
    /// `resolve`, which only ranks the signals that mean something.
    case album(colour: Color, playing: Bool)

    /// Priority order for the three signals the notch can carry at once.
    /// Attention interrupts everything (it's the one with a deadline), then a
    /// Live session, then background work.
    public static func resolve(attention: Bool, live: Bool, voiceLevel: CGFloat,
                               working: Bool,
                               activity: AgentActivity? = nil) -> NotchRimStyle {
        if attention { return .attention }
        if live { return .live(level: voiceLevel) }
        if working { return .working(activity: activity ?? .thinking) }
        return .none
    }
}

/// A stroke that traces the notch silhouette and carries ambient state —
/// the notch's own progress bar / status light.
///
/// Every mode draws it directly over its own `NotchPanelShape` background,
/// passing the same shape parameters, so the stroke lands exactly on that
/// mode's silhouette — the outline differs per mode (the music island contains
/// the cutout; the others hang below it).
///
/// The comet is driven by `TimelineView` (a clock read per frame) instead of a
/// `repeatForever` animation on published state: the phase is a pure function
/// of time, so it can't drift or fight the window resizes that happen whenever
/// the content grows.
struct NotchRim: View {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var bottom: CGFloat
    var style: NotchRimStyle

    /// Fraction of the outline the tool comet's tail covers.
    private let cometTail: CGFloat = 0.22
    /// Laps per second while a tool runs.
    private let cometRate: Double = 0.8

    @State private var breathe = false
    @State private var pulse = false

    private var shape: NotchPanelShape {
        NotchPanelShape(notchWidth: notchWidth, notchHeight: notchHeight, bottom: bottom)
    }

    var body: some View {
        switch style {
        case .none:
            EmptyView()
        case .live(let level):
            liveRim(level: level)
        case .working(let activity):
            workingRim(activity)
        case .attention:
            attentionRim
        case .album(let colour, let playing):
            albumRim(colour: colour, playing: playing)
        }
    }

    // MARK: - Live

    private func liveRim(level: CGFloat) -> some View {
        shape
            .stroke(LinearGradient(colors: [.cyan, .blue, .purple, .cyan],
                                   startPoint: .leading, endPoint: .trailing),
                    lineWidth: 1.8 + 2.2 * level)
            .blur(radius: 2)
            .opacity((breathe ? 0.85 : 0.4) + 0.25 * Double(level))
            .onAppear {
                breathe = false
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
            .transition(.opacity)
    }

    // MARK: - Working: one silhouette, three temperaments

    @ViewBuilder
    private func workingRim(_ activity: AgentActivity) -> some View {
        switch activity {
        case .thinking:   auroraRim
        case .tooling:    cometRim
        case .responding: tideRim
        }
    }

    /// **Thinking.** Two soft bands drift around the outline at different
    /// speeds and in opposite directions, blooming where they overlap, over a
    /// hairline that keeps the silhouette faintly lit and a wide dim wash that
    /// only reads out of the corner of your eye. Slow and blurred on purpose:
    /// reasoning has no progress to report, so the rim mustn't pretend it does.
    private var auroraRim: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let a = CGFloat((t * 0.13).truncatingRemainder(dividingBy: 1))
            let b = CGFloat((-t * 0.085).truncatingRemainder(dividingBy: 1))
            // One shared breath, so the whole rim swells together instead of
            // shimmering in pieces.
            let breath = 0.68 + 0.32 * (0.5 + 0.5 * sin(t * 2 * .pi / 5.2))
            ZStack {
                shape.stroke(Self.violet.opacity(0.16), lineWidth: 1.0).blur(radius: 2)
                shape.stroke(Self.violet.opacity(0.09), lineWidth: 7).blur(radius: 9)
                trail(head: a, length: 0.34, colour: Self.violet, width: 2.6, blur: 4.0)
                trail(head: b, length: 0.26, colour: Self.indigo, width: 2.0, blur: 5.0)
            }
            .opacity(breath)
        }
        .transition(.opacity)
    }

    /// **Tool call.** The one phase with a real beginning and end, so it gets
    /// the one motion that reads as progress: a warm comet lapping the
    /// outline, white-hot at the head. Faster and tighter than the aurora —
    /// this is the notch saying *something is happening right now*.
    private var cometRim: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let head = CGFloat(
                (context.date.timeIntervalSinceReferenceDate * cometRate)
                    .truncatingRemainder(dividingBy: 1))
            ZStack {
                shape.stroke(Self.amber.opacity(0.13), lineWidth: 1.0).blur(radius: 2)
                shape.stroke(Self.amber.opacity(0.07), lineWidth: 6).blur(radius: 8)
                trail(head: head, length: cometTail, colour: Self.amber,
                      core: Self.emberCore, width: 2.4, blur: 2.0)
            }
        }
        .transition(.opacity)
    }

    /// **Answering.** No travelling dot — the silhouette itself lights up in a
    /// band sweeping left to right, the direction the words are arriving from.
    private var tideRim: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let p = CGFloat((context.date.timeIntervalSinceReferenceDate * 0.42)
                .truncatingRemainder(dividingBy: 1))
            // Runs off both ends so the crest enters and leaves rather than
            // popping into existence at the edge.
            let x = p * 2.5 - 0.75
            let dim = Self.teal.opacity(0.12)
            let band = Gradient(stops: [
                .init(color: dim, location: 0),
                .init(color: dim, location: clamp01(x - 0.28)),
                .init(color: Self.mint, location: clamp01(x)),
                .init(color: dim, location: clamp01(x + 0.28)),
                .init(color: dim, location: 1),
            ])
            let sweep = LinearGradient(gradient: band, startPoint: .leading, endPoint: .trailing)
            ZStack {
                shape.stroke(sweep, lineWidth: 6).blur(radius: 8).opacity(0.45)
                shape.stroke(sweep, lineWidth: 2.0).blur(radius: 2.0)
            }
        }
        .transition(.opacity)
    }

    private func clamp01(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

    /// A comet tail along the outline: nested trims of decreasing length and
    /// rising brightness, standing in for the gradient-along-a-path SwiftUI
    /// won't stroke. Cheap, and much softer than a two-piece stroke.
    private func trail(head: CGFloat, length: CGFloat, colour: Color,
                       core: Color? = nil, width: CGFloat, blur: CGFloat,
                       steps: Int = 4) -> some View {
        ZStack {
            ForEach(0..<steps, id: \.self) { i in
                // 0 = the full faint tail … 1 = the short bright head.
                let t = CGFloat(i) / CGFloat(steps)
                let len = length * (1 - t)
                arc(from: head - len, length: len,
                    color: colour.opacity(0.14 + 0.26 * Double(t)),
                    width: width * (0.55 + 0.45 * t),
                    blur: blur * (1 - 0.5 * t))
            }
            if let core {
                arc(from: head - length * 0.05, length: length * 0.05,
                    color: core, width: width * 1.05, blur: blur * 0.35)
            }
        }
    }

    /// One arc along the outline. `trim` clamps rather than wraps, so a span
    /// crossing the end of the path is drawn as two pieces.
    @ViewBuilder
    private func arc(from start: CGFloat, length: CGFloat,
                     color: Color, width: CGFloat, blur: CGFloat) -> some View {
        // Heads sit *ahead* of their tails, so `start` is routinely negative;
        // normalise into [0, 1) before trimming.
        let s = (start.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let stroke = StrokeStyle(lineWidth: width, lineCap: .round)
        ZStack {
            shape.trim(from: s, to: min(1, s + length)).stroke(color, style: stroke)
            if s + length > 1 {
                shape.trim(from: 0, to: s + length - 1).stroke(color, style: stroke)
            }
        }
        .blur(radius: blur)
    }

    // MARK: - Attention

    private var attentionRim: some View {
        shape
            .stroke(Self.amber, lineWidth: pulse ? 3.0 : 1.4)
            .blur(radius: 2)
            .opacity(pulse ? 0.95 : 0.35)
            .onAppear {
                pulse = false
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .transition(.opacity)
    }

    // MARK: - Album

    /// A soft band of the record's own colour around the island. Steady and
    /// dim while paused, gently breathing while the track plays — it should
    /// read as the island being *warm*, not as a notification.
    private func albumRim(colour: Color, playing: Bool) -> some View {
        shape
            .stroke(LinearGradient(colors: [colour.opacity(0.15), colour, colour.opacity(0.15)],
                                   startPoint: .leading, endPoint: .trailing),
                    lineWidth: 1.6)
            .blur(radius: 2.2)
            .opacity(playing ? (breathe ? 0.75 : 0.4) : 0.3)
            .onAppear {
                guard playing else { return }
                breathe = false
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
            .transition(.opacity)
    }

    /// Work in progress, and the colour of anything with a deadline.
    static let amber = Color(red: 1.0, green: 0.68, blue: 0.25)
    /// White-hot head of the tool comet — the only near-white in the set, so
    /// it always reads as the leading edge.
    static let emberCore = Color(red: 1.0, green: 0.93, blue: 0.80)
    /// Thinking: periwinkle over indigo. Cool, unhurried, nothing to act on.
    static let violet = Color(red: 0.64, green: 0.53, blue: 1.0)
    static let indigo = Color(red: 0.36, green: 0.36, blue: 0.96)
    /// Answering: the words are on their way out.
    static let teal = Color(red: 0.24, green: 0.82, blue: 0.80)
    static let mint = Color(red: 0.60, green: 0.99, blue: 0.80)
}
