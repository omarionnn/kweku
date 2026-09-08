import SwiftUI

/// A new upload, announced.
///
/// Same shape and same motion as every other drop — it grows out of the
/// cutout, holds for its dwell, folds back — because a notice that arrived on
/// its own steam should not look like a different piece of software depending
/// on what it is about. What it adds is the thumbnail, and the thumbnail earns
/// its place: a video title alone rarely tells you whether you want to stop
/// what you're doing, and the frame usually does it instantly.
///
/// The motion is staged rather than simultaneous. Panel, then picture, then
/// the play mark landing on it, then the words — about 120ms apart, which is
/// enough to read as one thing arriving rather than four things appearing.
struct YouTubeDropView: View {
    var drop: NotchDrop
    var shownAt: Date
    var presenting: Bool
    @ObservedObject var vm: NotchViewModel
    /// Open the video.
    var onTap: () -> Void

    static let bodyHeight: CGFloat = 62
    static let expandedWidth: CGFloat = 384

    /// The brand mark is pure red — that is what makes it read as YouTube at a
    /// glance and not just "a red rectangle".
    private static let brand = Color(red: 1, green: 0, blue: 0)
    /// The rim is softened. Saturated red on a thin moving arc against black
    /// vibrates; this keeps the identity without the buzz.
    private static let rim = Color(red: 1, green: 0.22, blue: 0.22)

    private static let thumbHeight: CGFloat = 38
    private static var thumbWidth: CGFloat { thumbHeight * 16 / 9 }

    @State private var reveal: CGFloat = 0
    @State private var artIn = false
    @State private var badgeIn = false
    @State private var textIn = false

    var body: some View {
        let cutoutH = vm.notchSize.height
        let notchW = vm.notchSize.width

        GeometryReader { proxy in
            let fullW = min(proxy.size.width, Self.expandedWidth)
            let panelW = notchW + (fullW - notchW) * reveal
            let panelH = Self.bodyHeight * reveal

            ZStack(alignment: .top) {
                Color.clear
                ZStack(alignment: .top) {
                    NotchPanelShape(notchWidth: notchW, notchHeight: cutoutH,
                                    bottom: 6 + 10 * reveal)
                        .fill(Color.black)
                    // Read per frame, not per layout pass: the rim has no
                    // motion of its own, so the clock has to come from here.
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                        NotchRim(notchWidth: notchW, notchHeight: cutoutH,
                                 bottom: 6 + 10 * reveal,
                                 style: .progress(fraction: remaining(at: context.date),
                                                  colour: Self.rim))
                    }
                    body(width: panelW, height: panelH)
                        .frame(width: panelW, height: panelH)
                        .offset(y: cutoutH)
                }
                .frame(width: panelW, height: cutoutH + panelH)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onAppear { open() }
        .onChange(of: presenting) { showing in if showing { open() } else { close() } }
    }

    /// What's left of the dwell, 1 → 0; a pure read of the clock so it cannot
    /// drift away from the retraction it is counting down to.
    private func remaining(at now: Date) -> CGFloat {
        guard presenting, drop.dwell > 0 else { return 0 }
        let gone = now.timeIntervalSince(shownAt)
        return CGFloat(max(0, min(1, 1 - gone / drop.dwell)))
    }

    @ViewBuilder
    private func body(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 11) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(drop.title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Self.rim.opacity(0.95))
                        .lineLimit(1)
                    Text("uploaded")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Text(drop.detail)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .offset(x: textIn ? 0 : -8)
            .opacity(textIn ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .center)
        .clipped()
    }

    private var thumbnail: some View {
        ZStack {
            // A red bloom under the frame. Barely visible, but it stops the
            // picture reading as a sticker pasted onto black.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Self.brand.opacity(0.34))
                .blur(radius: 9)
                .opacity(artIn ? 1 : 0)

            Group {
                if let image = YouTubeThumbnails.image(for: drop.artURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // The fetch is meant to have happened before this was
                    // posted; if it didn't, the shape still has to be right or
                    // the whole row jumps when the picture is missing.
                    LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: Self.thumbWidth, height: Self.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5))

            playBadge
        }
        .frame(width: Self.thumbWidth, height: Self.thumbHeight)
        .scaleEffect(artIn ? 1 : 0.82)
        .opacity(artIn ? 1 : 0)
    }

    /// The play mark, landing on the frame a beat after it appears.
    private var playBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(Self.brand)
                .frame(width: 21, height: 15)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            PlayTriangle()
                .fill(Color.white)
                .frame(width: 6, height: 7)
                .offset(x: 0.6)
        }
        .scaleEffect(badgeIn ? 1 : 0.3)
        .opacity(badgeIn ? 1 : 0)
    }

    // MARK: - Motion

    private func open() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) { reveal = 1 }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.7).delay(0.08)) { artIn = true }
        // Lower damping than the rest: the badge is the one element allowed to
        // overshoot, which is what makes it read as landing rather than fading.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.52).delay(0.2)) { badgeIn = true }
        withAnimation(.easeOut(duration: 0.2).delay(0.14)) { textIn = true }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.09)) {
            textIn = false; badgeIn = false; artIn = false
        }
        withAnimation(.spring(response: 0.24, dampingFraction: 1).delay(0.06)) { reveal = 0 }
    }
}

/// The play glyph, drawn rather than borrowed from SF Symbols so it keeps the
/// proportions of the real mark at this size.
private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
