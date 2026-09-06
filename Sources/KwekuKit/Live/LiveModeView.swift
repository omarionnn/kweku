import SwiftUI

/// Live mode: the nook while a Kweku Live session is running.
///
/// Live used to be a rim glow, a two-line caption strip, and a status string
/// you could only read by right-clicking. That left the three questions a voice
/// session actually raises unanswered on screen: is it connected, can it hear
/// me, and what can it see. This is a component in its own right — it takes the
/// nook over for the duration, the way the music island does, because a session
/// you started deliberately outranks whatever was idling there.
///
/// Collapsed: state, mic level, and the window being streamed, in one band.
/// Expanded: the same plus the transcript and the controls that used to require
/// the context menu.
struct LiveModeView: View, NookComponent {
    @ObservedObject var live: LiveSessionController
    @ObservedObject var audio: AudioEngineManager
    @ObservedObject var vm: NotchViewModel
    var rim: NotchRimStyle

    static let peek: CGFloat = 32
    static let expandedBody: CGFloat = 116
    static let expandedWidth: CGFloat = 380

    static func metrics(_ context: NookContext) -> NookMetrics {
        NookMetrics(peek: peek, expandedBody: expandedBody, expandedWidth: expandedWidth)
    }

    private var expanded: Bool { vm.isHovering || vm.expanded }

    private var activity: LiveActivity {
        LiveActivity.resolve(phase: live.phase, speaking: live.speaking,
                             composing: live.composing,
                             muted: audio.micMuted, gated: audio.micGated)
    }

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
            StateDot(activity: activity, tint: tint)
            Text(activity.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            MicMeter(level: CGFloat(audio.currentMicAmplitude), bars: 4,
                     silenced: audio.micMuted || audio.micGated, tint: tint)
                .frame(width: 22, height: 11)
            if !vision.isEmpty {
                Circle().fill(Color.white.opacity(0.22)).frame(width: 2.5, height: 2.5)
                eyeLine(compact: true)
            }
        }
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            transcript
            controls
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 9)
    }

    /// State and session clock on the left, what Kweku can see on the right.
    private var header: some View {
        HStack(spacing: 7) {
            StateDot(activity: activity, tint: tint)
            Text(activity.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            // The reason a session is unhealthy, when there is one — this is
            // the line that used to live behind a right-click.
            if live.phase.isTrouble {
                Text(live.phase.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NotchRim.amber.opacity(0.9))
                    .lineLimit(1).truncationMode(.tail)
            } else if let started = live.startedAt {
                SessionClock(startedAt: started)
            }
            Spacer(minLength: 8)
            eyeLine(compact: false)
        }
    }

    /// What Kweku heard, and what it's saying. Same two lines as the old strip,
    /// with the space reserved either way so the panel doesn't jump as speech
    /// starts and stops.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(live.heard.isEmpty ? " " : live.heard)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1).truncationMode(.head)
            Text(live.caption.isEmpty ? " " : live.caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(live.caption.isEmpty ? 0 : 0.92))
                .lineLimit(1).truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: live.heard)
        .animation(.easeInOut(duration: 0.2), value: live.caption)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            MicMeter(level: CGFloat(audio.currentMicAmplitude), bars: 9,
                     silenced: audio.micMuted || audio.micGated, tint: tint)
                .frame(height: 12)
            Spacer(minLength: 8)
            control(audio.micMuted ? "mic.slash.fill" : "mic.fill",
                    help: audio.micMuted ? "Unmute the microphone" : "Mute the microphone",
                    tint: audio.micMuted ? NotchRim.amber : .white,
                    enabled: live.running) {
                live.toggleMute()
            }
            // Only offered while there's a sentence to cut off; a dead button
            // is a better answer than one that silently does nothing.
            control("hand.raised.fill", help: "Stop Kweku talking",
                    tint: .white, enabled: live.speaking) {
                live.hush()
            }
            control("stop.fill", help: "End the Live session",
                    tint: NotchRim.amber, enabled: live.running) {
                live.stop()
            }
        }
    }

    // MARK: - Vision

    private var vision: String { live.vision.label }

    /// The eye line: which window is being streamed off this machine, and
    /// whether it's being blanked first. Deliberately always present while a
    /// session runs — an indicator you only see sometimes is not an indicator.
    private func eyeLine(compact: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: visionSymbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(visionTint)
            Text(LiveFormat.title(vision, limit: compact ? 18 : 30))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(visionTint.opacity(0.85))
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var visionSymbol: String {
        if live.vision.isBlind { return "eye.slash" }
        return live.vision.isRedacted ? "eye.trianglebadge.exclamationmark" : "eye"
    }

    /// Blind is a fault, redacted is a *reassurance* — the frame is being held
    /// back on purpose — so they must not wear the same colour.
    private var visionTint: Color {
        if live.vision.isBlind { return NotchRim.amber }
        return live.vision.isRedacted ? AgentPanelView.ready : .white.opacity(0.55)
    }

    // MARK: - Colour

    /// One colour per activity, matching the rim's palette so the panel and the
    /// outline never disagree about what Kweku is doing.
    private var tint: Color {
        switch activity {
        case .connecting: return NotchRim.amber
        case .listening:  return NotchRim.mint
        case .thinking:   return NotchRim.violet
        case .speaking:   return NotchRim.teal
        case .muted:      return NotchRim.amber
        case .held:       return .white.opacity(0.45)
        case .ended:      return .white.opacity(0.35)
        }
    }

    private func control(_ symbol: String, help: String, tint: Color,
                         enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(LiveControlButtonStyle(enabled: enabled))
        .disabled(!enabled)
        .help(help)
    }
}

/// The session clock. Its own view with its own `TimelineView` so ticking the
/// seconds doesn't rebuild the whole panel — and so nothing ticks at all once
/// the session ends and the clock is gone.
private struct SessionClock: View {
    var startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(LiveFormat.duration(context.date.timeIntervalSince(startedAt)))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .monospacedDigit()
        }
    }
}

/// The state light. Breathes while Kweku has the floor or is thinking, and sits
/// still otherwise — motion means "something is happening", so an idle
/// listening dot that pulsed would be lying.
private struct StateDot: View {
    var activity: LiveActivity
    var tint: Color

    @State private var big = false

    private var animated: Bool {
        switch activity {
        case .speaking, .thinking, .connecting: return true
        case .listening, .muted, .held, .ended:  return false
        }
    }

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .scaleEffect(animated && big ? 1.35 : 0.85)
            .opacity(animated && big ? 1 : 0.6)
            .onAppear { restart() }
            .onChange(of: animated) { _ in restart() }
    }

    private func restart() {
        big = false
        guard animated else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            big = true
        }
    }
}

/// Microphone input as a bar meter.
///
/// `silenced` covers both reasons the meter can be flat while you're talking —
/// muted by hand, or held by the half-duplex gate while Kweku speaks — and
/// draws them as a struck-through track rather than just an empty one, so
/// "nothing is reaching the mic" never looks the same as "the room is quiet".
struct MicMeter: View {
    var level: CGFloat
    var bars: Int
    var silenced: Bool
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let count = max(1, bars)
            let spacing: CGFloat = 2
            let barWidth = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let lit = silenced ? 0 : Int((level * CGFloat(count)).rounded())
            ZStack {
                HStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { index in
                        Capsule()
                            .fill(index < lit ? tint : Color.white.opacity(0.16))
                            .frame(width: barWidth)
                            // Taller towards the middle: reads as a level meter
                            // rather than a progress bar.
                            .frame(height: height(index, of: count, in: geo.size.height))
                            .frame(maxHeight: .infinity)
                    }
                }
                if silenced {
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(height: 1)
                }
            }
            .animation(.linear(duration: 0.08), value: lit)
        }
    }

    private func height(_ index: Int, of count: Int, in full: CGFloat) -> CGFloat {
        guard count > 1 else { return full }
        let middle = Double(count - 1) / 2
        let distance = abs(Double(index) - middle) / middle
        return full * CGFloat(0.45 + 0.55 * (1 - distance))
    }
}

/// Hover/press feedback for the Live controls, with a real disabled state —
/// the hush button spends most of its life unavailable, and it should look it.
private struct LiveControlButtonStyle: ButtonStyle {
    var enabled: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(!enabled ? 0.25 : (configuration.isPressed ? 0.5 : (hovering ? 1 : 0.7)))
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(hovering && enabled ? 0.12 : 0))
            )
            .scaleEffect(configuration.isPressed && enabled ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: enabled)
            .onHover { hovering = $0 }
    }
}
