import SwiftUI

/// The notch saying one line and going away again.
///
/// Same shape and same motion as the command panel, on purpose: the notch has
/// one way of opening, and a notice that arrived under its own steam should
/// not look like a different piece of software from one you summoned. It grows
/// out of the cutout, holds for its dwell, and folds back.
///
/// The rim carries the countdown, so the retraction is never a surprise —
/// the arc emptying *is* the warning that the line is about to go.
struct DropView: View {
    var drop: NotchDrop
    /// When the line appeared; the countdown is read off this and the clock.
    var shownAt: Date
    /// False once it's folding away.
    var presenting: Bool
    @ObservedObject var vm: NotchViewModel
    /// Open the notch on it — a line worth reading is often a line worth
    /// acting on, and the panel behind it has the detail.
    var onTap: () -> Void

    static let bodyHeight: CGFloat = 46
    static let expandedWidth: CGFloat = 320

    @State private var reveal: CGFloat = 0
    @State private var contentIn = false

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
                    // The countdown has to be read per frame, not per layout
                    // pass — the progress rim deliberately has no motion of
                    // its own, so the clock has to come from here.
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                        NotchRim(notchWidth: notchW, notchHeight: cutoutH,
                                 bottom: 6 + 10 * reveal,
                                 style: .progress(fraction: remaining(at: context.date),
                                                  colour: tint))
                    }
                    line
                        .opacity(contentIn ? 1 : 0)
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

    /// What's left of the dwell, 1 → 0. A pure read of the clock, like the
    /// comet, so it cannot drift away from the retraction it's counting down.
    private func remaining(at now: Date) -> CGFloat {
        guard presenting, drop.dwell > 0 else { return 0 }
        let gone = now.timeIntervalSince(shownAt)
        return CGFloat(max(0, min(1, 1 - gone / drop.dwell)))
    }

    private var tint: Color {
        switch drop.tint {
        case .attention: return NotchRim.amber
        case .done:      return NotchRim.mint
        case .neutral:   return .white
        }
    }

    private var line: some View {
        HStack(spacing: 9) {
            Image(systemName: drop.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(drop.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1).truncationMode(.middle)
                Text(drop.detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func open() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) { reveal = 1 }
        withAnimation(.easeOut(duration: 0.16).delay(0.06)) { contentIn = true }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.09)) { contentIn = false }
        withAnimation(.spring(response: 0.24, dampingFraction: 1).delay(0.06)) { reveal = 0 }
    }
}
