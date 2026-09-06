import SwiftUI

/// The creature in its notch nook. Draws the shared `NotchPanelShape` (which,
/// at notch width, is a flush nook) as its own background and places the face
/// in the visible band below the cutout. Self-contained + a `Color.clear`
/// flexible filler — the layout pattern that stays stable inside the overlay
/// window.
struct CreatureView: View {
    @ObservedObject var state: CreatureState
    @ObservedObject var vm: NotchViewModel
    var rim: NotchRimStyle
    @State private var breathe = false

    @State private var emberPulse = false

    /// Height of the face band that hangs below the notch cutout.
    static let peek: CGFloat = 30

    /// Slide speed (points/sec) at which the lean maxes out.
    private static let leanReach: CGFloat = 1400
    /// Degrees of body lean at full speed.
    private static let leanDegrees: CGFloat = 13

    var body: some View {
        let width = vm.notchSize.width
        let cutoutH = vm.notchSize.height
        let totalH = cutoutH + Self.peek

        let eyeH: CGFloat = 15
        let eyeW: CGFloat = 13.5
        let pupilR = eyeW * 0.24
        let travel = max(0, eyeW / 2 - pupilR - 0.5)
        let eyeDX = eyeW / 2 + 3.5
        let eyeCY: CGFloat = 3

        ZStack(alignment: .top) {
            Color.clear
            ZStack(alignment: .top) {
                NotchPanelShape(notchWidth: width, notchHeight: cutoutH, bottom: 12).fill(Color.black)
                NotchRim(notchWidth: width, notchHeight: cutoutH, bottom: 12, style: rim)
                face(eyeW: eyeW, eyeH: eyeH, pupilR: pupilR, travel: travel, eyeDX: eyeDX, eyeCY: eyeCY)
                    .frame(width: width, height: Self.peek)
                    .scaleEffect(state.popScale)
                    // Body leans into a sideways slide and swings back as the
                    // spring returns it — pivoting from the cutout, so the face
                    // hangs off the notch like a head off a neck.
                    .rotationEffect(.degrees(lean), anchor: .top)
                    .offset(x: -lean * 0.35, y: cutoutH + (breathe ? -0.6 : 0.6))
            }
            .frame(width: width, height: totalH)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.16, dampingFraction: 0.6), value: state.gaze)
        .animation(.easeInOut(duration: 0.25), value: state.charging)
        .animation(.easeInOut(duration: 0.25), value: state.capsLock)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: state.cameraActive)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: state.agentWaiting)
        .animation(.easeInOut(duration: 0.45), value: state.agentActivity)
        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: vm.slideVelocity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    /// Body tilt in degrees, trailing the slide: moving right tips the face
    /// left, as though the head lags behind the body.
    private var lean: Double {
        let v = min(max(vm.slideVelocity / Self.leanReach, -1), 1)
        return Double(-v * Self.leanDegrees)
    }

    /// The ember under the chin, tinted to match whichever rim is running.
    /// Thinking has no ember — it has motes instead.
    private var emberColour: Color? {
        switch state.agentActivity {
        case .tooling:    return NotchRim.amber
        case .responding: return NotchRim.teal
        case .thinking, nil: return nil
        }
    }

    /// Motes: slow violet specks rising through the empty band either side of
    /// the face while an agent reasons. Driven from a clock rather than
    /// `repeatForever` so they stay in step with the rim's aurora and can't
    /// drift out of phase across the window resizes the notch does constantly.
    private var motes: some View {
        // Keep them off the face and inside the panel on narrow notches.
        let reach = max(20, vm.notchSize.width / 2 - 8)
        return TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<6, id: \.self) { i in
                    let seed = Double(i) * 2.3
                    let period = 5.5 + Double(i % 3) * 2.2
                    let p = CGFloat((((t + seed * 3) / period)
                        .truncatingRemainder(dividingBy: 1) + 1)
                        .truncatingRemainder(dividingBy: 1))
                    let side: CGFloat = i % 2 == 0 ? -1 : 1
                    Circle()
                        .fill(NotchRim.violet)
                        .frame(width: 2.4, height: 2.4)
                        .blur(radius: 0.7)
                        // Fade in and out at the ends of the climb, so they
                        // arrive and leave rather than blink.
                        .opacity(0.8 * Double(sin(p * .pi)))
                        .offset(x: side * min(24 + CGFloat(i / 2) * 13, reach)
                                   + CGFloat(sin(t * 0.9 + seed)) * 3,
                                y: 14 - 26 * p)
                }
            }
        }
    }

    private func face(eyeW: CGFloat, eyeH: CGFloat, pupilR: CGFloat, travel: CGFloat,
                      eyeDX: CGFloat, eyeCY: CGFloat) -> some View {
        ZStack {
            // Thinking gets motes drifting in the empty band either side of
            // the face; the busier phases get an ember under the chin, in the
            // same colour their rim is wearing.
            if state.agentActivity == .thinking {
                motes.transition(.opacity)
            } else if let ember = emberColour {
                Circle()
                    .fill(RadialGradient(colors: [ember.opacity(0.85), ember.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 11))
                    .frame(width: 22, height: 22)
                    .scaleEffect(emberPulse ? 1.25 : 0.8)
                    .opacity(emberPulse ? 1.0 : 0.55)
                    .offset(y: eyeCY + eyeH * 0.85)
                    .onAppear {
                        emberPulse = false
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                            emberPulse = true
                        }
                    }
                    .transition(.opacity)
            }
            ear().offset(x: -eyeDX, y: -8).rotationEffect(.degrees(-state.earTwitch * 16), anchor: .bottom)
            ear().offset(x: eyeDX, y: -8).rotationEffect(.degrees(state.earTwitch * 16), anchor: .bottom)

            cheek().offset(x: -eyeDX - 4, y: eyeCY + eyeH * 0.55)
            cheek().offset(x: eyeDX + 4, y: eyeCY + eyeH * 0.55)

            brow(eyeW: eyeW).offset(x: -eyeDX, y: eyeCY - eyeH / 2 - (state.capsLock ? 5 : 2.5))
                .opacity(state.capsLock ? 1 : 0)
            brow(eyeW: eyeW).offset(x: eyeDX, y: eyeCY - eyeH / 2 - (state.capsLock ? 5 : 2.5))
                .opacity(state.capsLock ? 1 : 0)

            // Eyes — become exclamation marks while an agent waits on the user.
            if state.agentWaiting {
                exclaim(eyeH: eyeH).offset(x: -eyeDX, y: eyeCY)
                    .transition(.scale.combined(with: .opacity))
                exclaim(eyeH: eyeH).offset(x: eyeDX, y: eyeCY)
                    .transition(.scale.combined(with: .opacity))
            } else {
                // Eyes narrow while a tool runs — the face of watching
                // something happen rather than deciding what to do.
                let open = state.eyeOpenAmount * (state.agentActivity == .tooling ? 0.72 : 1)
                eye(eyeW: eyeW, eyeH: eyeH, pupilR: pupilR, travel: travel, open: open)
                    .offset(x: -eyeDX, y: eyeCY)
                eye(eyeW: eyeW, eyeH: eyeH, pupilR: pupilR, travel: travel, open: open)
                    .offset(x: eyeDX, y: eyeCY)
            }

            if state.cameraActive {
                shades(eyeW: eyeW, eyeH: eyeH, eyeDX: eyeDX, eyeCY: eyeCY)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Mouth: drops, yawns, and Live-session lip-sync all drive it.
            let mouth = max(state.mouthOpen, state.voiceLevel)
            Ellipse().fill(Color.white.opacity(0.9))
                .frame(width: eyeW * (1.2 + 0.5 * mouth), height: max(0.5, mouth * 8))
                .opacity(mouth)
                .offset(y: eyeCY + eyeH * 0.7)
                .animation(.linear(duration: 0.08), value: state.voiceLevel)
        }
    }

    private func ear() -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.16)).frame(width: 6, height: 8)
    }

    /// An exclamation mark sized like an eye: bar + dot, in eye-white.
    private func exclaim(eyeH: CGFloat) -> some View {
        VStack(spacing: 2) {
            Capsule().fill(Color.white.opacity(0.95))
                .frame(width: 3.6, height: eyeH * 0.62)
            Circle().fill(Color.white.opacity(0.95))
                .frame(width: 3.6, height: 3.6)
        }
        .frame(height: eyeH)
    }
    private func cheek() -> some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.5, blue: 0.45),
                                          Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.2)],
                                 center: .center, startRadius: 0, endRadius: 6))
            .frame(width: 10, height: 10).opacity(state.charging ? 0.95 : 0).blur(radius: 0.6)
    }
    private func brow(eyeW: CGFloat) -> some View {
        Capsule().fill(Color.white.opacity(0.85)).frame(width: eyeW * 0.9, height: 2)
    }
    private func eye(eyeW: CGFloat, eyeH: CGFloat, pupilR: CGFloat, travel: CGFloat, open: CGFloat) -> some View {
        let offset = CGSize(width: state.gaze.width * travel, height: state.gaze.height * travel)
        return ZStack {
            Capsule().fill(Color.white.opacity(0.92))
            Circle().fill(Color.black).frame(width: pupilR * 2, height: pupilR * 2).offset(offset)
        }
        .frame(width: eyeW, height: eyeH).clipShape(Capsule())
        .scaleEffect(x: 1, y: max(0.05, open), anchor: .center)
        .animation(.easeInOut(duration: 0.18), value: open)
    }
    private func shades(eyeW: CGFloat, eyeH: CGFloat, eyeDX: CGFloat, eyeCY: CGFloat) -> some View {
        let lensW = eyeW * 1.5, lensH = eyeH * 1.15
        return ZStack {
            Capsule().fill(Color(white: 0.1)).frame(width: (eyeDX * 2 - lensW) + 8, height: 2.6)
                .offset(y: eyeCY - lensH * 0.18)
            lens(w: lensW, h: lensH).offset(x: -eyeDX, y: eyeCY)
            lens(w: lensW, h: lensH).offset(x: eyeDX, y: eyeCY)
        }
    }
    private func lens(w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: h * 0.45, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: h * 0.45, style: .continuous).strokeBorder(Color(white: 0.28), lineWidth: 0.6))
            .overlay(Capsule().fill(Color.white.opacity(0.35)).frame(width: w * 0.5, height: 1.6)
                .rotationEffect(.degrees(-32)).offset(x: -w * 0.12, y: -h * 0.18))
            .frame(width: w, height: h)
    }
}
