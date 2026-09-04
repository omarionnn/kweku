import SwiftUI

/// The creature in its notch nook. Draws the shared `NotchPanelShape` (which,
/// at notch width, is a flush nook) as its own background and places the face
/// in the visible band below the cutout. Self-contained + a `Color.clear`
/// flexible filler — the layout pattern that stays stable inside the overlay
/// window.
struct CreatureView: View {
    @ObservedObject var state: CreatureState
    @ObservedObject var vm: NotchViewModel
    @State private var breathe = false

    @State private var emberPulse = false

    /// Height of the face band that hangs below the notch cutout.
    static let peek: CGFloat = 30

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
                face(eyeW: eyeW, eyeH: eyeH, pupilR: pupilR, travel: travel, eyeDX: eyeDX, eyeCY: eyeCY)
                    .frame(width: width, height: Self.peek)
                    .scaleEffect(state.popScale)
                    .offset(y: cutoutH + (breathe ? -0.6 : 0.6))
            }
            .frame(width: width, height: totalH)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.16, dampingFraction: 0.6), value: state.gaze)
        .animation(.easeInOut(duration: 0.25), value: state.charging)
        .animation(.easeInOut(duration: 0.25), value: state.capsLock)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: state.cameraActive)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private func face(eyeW: CGFloat, eyeH: CGFloat, pupilR: CGFloat, travel: CGFloat,
                      eyeDX: CGFloat, eyeCY: CGFloat) -> some View {
        ZStack {
            // Amber ember: pulses while any coding-agent session is working.
            if state.agentWorking {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(red: 1.0, green: 0.68, blue: 0.25).opacity(0.85),
                                 Color(red: 1.0, green: 0.5, blue: 0.1).opacity(0)],
                        center: .center, startRadius: 0, endRadius: 11))
                    .frame(width: 22, height: 22)
                    .scaleEffect(emberPulse ? 1.25 : 0.8)
                    .opacity(emberPulse ? 1.0 : 0.55)
                    .offset(y: eyeCY + eyeH * 0.85)
                    .onAppear {
                        emberPulse = false
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
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

            eye(eyeW: eyeW, eyeH: eyeH, pupilR: pupilR, travel: travel, open: state.eyeOpenAmount)
                .offset(x: -eyeDX, y: eyeCY)
            eye(eyeW: eyeW, eyeH: eyeH, pupilR: pupilR, travel: travel, open: state.eyeOpenAmount)
                .offset(x: eyeDX, y: eyeCY)

            if state.cameraActive {
                shades(eyeW: eyeW, eyeH: eyeH, eyeDX: eyeDX, eyeCY: eyeCY)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Ellipse().fill(Color.white.opacity(0.9))
                .frame(width: eyeW * 1.5, height: max(0.5, state.mouthOpen * 7))
                .opacity(state.mouthOpen)
                .offset(y: eyeCY + eyeH * 0.7)
        }
    }

    private func ear() -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.16)).frame(width: 6, height: 8)
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
