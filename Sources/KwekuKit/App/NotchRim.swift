import SwiftUI

/// One agent's share of a segmented rim.
public struct RimSegment: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        case working(AgentActivity)
        case waiting
        case idle
    }

    public var id: String
    public var state: State

    public init(id: String, state: State) {
        self.id = id
        self.state = state
    }
}

/// A span of the outline, as a fraction of its length.
public struct RimArc: Equatable, Sendable {
    public var start: CGFloat
    public var length: CGFloat

    public init(start: CGFloat, length: CGFloat) {
        self.start = start
        self.length = length
    }
}

/// Dividing the outline between several sessions.
///
/// Pure, so the arithmetic that decides whether four agents each still get a
/// readable arc can be checked without a screen.
public enum RimSegments {
    /// Gap between neighbouring arcs, as a fraction of the outline. Without
    /// one, four arcs read as a single unbroken ring.
    public static let gap: CGFloat = 0.025
    /// Past this many the arcs are too short to tell apart, and the rim stops
    /// trying to be a list.
    public static let maxArcs = 5

    public static func arcs(count: Int, gap: CGFloat = gap) -> [RimArc] {
        guard count > 0 else { return [] }
        let shown = min(count, maxArcs)
        let span = 1 / CGFloat(shown)
        return (0..<shown).map {
            RimArc(start: CGFloat($0) * span + gap / 2, length: max(0.015, span - gap))
        }
    }
}

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
    /// More than one session at once: the outline is divided between them,
    /// one arc each, each in its own state.
    ///
    /// `activity` ranks several working sessions down to a single winner and
    /// throws the rest away, which is right for one silhouette and wrong for
    /// the question you actually have with three agents running — how many,
    /// and is any of them stuck. Waiting arcs blink; working arcs breathe.
    case sessions([RimSegment])
    /// Something with a genuinely known extent, 0…1.
    ///
    /// Deliberately rare, and never inferred. The aurora exists because
    /// reasoning has no progress to report and the rim must not pretend it
    /// does; this is only for things that really do have a measurable end,
    /// like how long a drop has left before it retracts.
    case progress(fraction: CGFloat, colour: Color)
    /// Music is playing and the cover has a colour worth wearing. The lowest
    /// priority signal there is — purely ambient, never competing with a state
    /// you need to act on. Resolved by the music island itself rather than
    /// `resolve`, which only ranks the signals that mean something.
    case album(colour: Color, playing: Bool)

    /// Priority order for the signals the notch can carry at once.
    ///
    /// Attention interrupts everything — it's the one with a deadline. After
    /// that the ranking turns on whether Kweku is *actually speaking*: while a
    /// sentence is coming out, the rim is his mouth moving and nothing may take
    /// it. The instant he goes quiet, work outranks the idle Live glow, because
    /// a dispatched task is the only thing left worth watching — and it's
    /// exactly the moment the old ordering went blank, holding a decorative
    /// breathing gradient over a running build.
    ///
    /// `speaking` is the audio engine's drain state rather than `voiceLevel`,
    /// which crosses any threshold you pick several times a syllable and would
    /// strobe the rim between two styles.
    /// `segments` outranks `attention` once there are two or more sessions:
    /// the segmented rim can say "one of these is waiting" *and* what the
    /// others are doing, where the amber pulse says only the first half and
    /// blanks everything else. With a single session the pulse is still the
    /// better signal, and nothing is lost by it.
    public static func resolve(attention: Bool, live: Bool, speaking: Bool = false,
                               voiceLevel: CGFloat, working: Bool,
                               activity: AgentActivity? = nil,
                               segments: [RimSegment] = []) -> NotchRimStyle {
        if segments.count >= 2 { return .sessions(segments) }
        if attention { return .attention }
        if live && speaking { return .live(level: voiceLevel) }
        if working { return .working(activity: activity ?? .thinking) }
        if live { return .live(level: voiceLevel) }
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
        case .sessions(let segments):
            sessionsRim(segments)
        case .progress(let fraction, let colour):
            progressRim(fraction: fraction, colour: colour)
        case .album(let colour, let playing):
            albumRim(colour: colour, playing: playing)
        }
    }

    // MARK: - Several sessions at once

    /// One arc per session around the outline, over a hairline that keeps the
    /// whole silhouette faintly present — so the arcs read as *parts of* the
    /// rim rather than as free-floating marks.
    ///
    /// Waiting and tooling share amber deliberately: they're the same colour
    /// of urgency, and what separates them is the rhythm. A waiting arc blinks
    /// at just under a second; a working one breathes over two and a half.
    private func sessionsRim(_ segments: [RimSegment]) -> some View {
        let arcs = RimSegments.arcs(count: segments.count)
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                shape.stroke(Color.white.opacity(0.06), lineWidth: 1)
                ForEach(arcs.indices, id: \.self) { index in
                    segmentArc(segments[index], arc: arcs[index], at: t)
                }
            }
        }
        .transition(.opacity)
    }

    private func segmentArc(_ segment: RimSegment, arc span: RimArc,
                            at t: TimeInterval) -> some View {
        let level: CGFloat
        switch segment.state {
        case .waiting:
            level = 0.4 + 0.6 * CGFloat(0.5 + 0.5 * sin(t * 2 * .pi / 0.9))
        case .working:
            level = 0.45 + 0.35 * CGFloat(0.5 + 0.5 * sin(t * 2 * .pi / 2.6))
        case .idle:
            level = 0.2
        }
        let colour = Self.colour(for: segment.state)
        return ZStack {
            arc(from: span.start, length: span.length,
                color: colour.opacity(Double(level) * 0.3), width: 5, blur: 6)
            arc(from: span.start, length: span.length,
                color: colour.opacity(Double(level)), width: 2.2, blur: 1.6)
        }
    }

    static func colour(for state: RimSegment.State) -> Color {
        switch state {
        case .waiting: return amber
        case .idle:    return .white
        case .working(let activity):
            switch activity {
            case .thinking:   return violet
            case .tooling:    return amber
            case .responding: return teal
            }
        }
    }

    // MARK: - Progress

    /// A single arc from the top, filled to `fraction`. No motion of its own —
    /// the number moving *is* the animation, and anything else on top of it
    /// would only make a measured thing look busy.
    private func progressRim(fraction: CGFloat, colour: Color) -> some View {
        let filled = clamp01(fraction)
        return ZStack {
            shape.stroke(colour.opacity(0.09), lineWidth: 1)
            shape.trim(from: 0, to: filled)
                .stroke(colour.opacity(0.75),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .blur(radius: 1.2)
        }
        .transition(.opacity)
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
