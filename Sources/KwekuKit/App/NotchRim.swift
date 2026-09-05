import SwiftUI

/// What the rim is saying. One style at a time, highest urgency wins — see
/// `NotchRimStyle.resolve`.
public enum NotchRimStyle: Equatable {
    /// Nothing to report; the rim isn't drawn at all.
    case none
    /// A Kweku Live session is open. Breathing gradient, brighter while Kweku
    /// speaks (`level` is the 0…1 speech amplitude).
    case live(level: CGFloat)
    /// At least one agent session is executing: an amber comet laps the outline.
    case working
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
                               working: Bool) -> NotchRimStyle {
        if attention { return .attention }
        if live { return .live(level: voiceLevel) }
        if working { return .working }
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

    /// Fraction of the outline the comet's tail covers.
    private let cometTail: CGFloat = 0.18
    /// Fraction covered by its bright head.
    private let cometHead: CGFloat = 0.05
    /// Laps per second.
    private let cometRate: Double = 0.55

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
        case .working:
            cometRim
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

    // MARK: - Working comet

    private var cometRim: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = CGFloat(
                (context.date.timeIntervalSinceReferenceDate * cometRate)
                    .truncatingRemainder(dividingBy: 1))
            ZStack {
                arc(from: phase, length: cometTail,
                    color: Self.amber.opacity(0.35), width: 1.6, blur: 1.5)
                arc(from: phase + cometTail - cometHead, length: cometHead,
                    color: Self.amber, width: 2.2, blur: 0.8)
            }
        }
        .transition(.opacity)
    }

    /// One arc along the outline. `trim` clamps rather than wraps, so a span
    /// crossing the end of the path is drawn as two pieces.
    @ViewBuilder
    private func arc(from start: CGFloat, length: CGFloat,
                     color: Color, width: CGFloat, blur: CGFloat) -> some View {
        let s = start.truncatingRemainder(dividingBy: 1)
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

    static let amber = Color(red: 1.0, green: 0.68, blue: 0.25)
}
