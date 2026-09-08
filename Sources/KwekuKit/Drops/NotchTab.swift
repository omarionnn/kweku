import SwiftUI

/// The part of a notice that outlives the notice.
///
/// A drop says a thing for two seconds and folds away, which is the right
/// shape for news and the wrong shape for a debt. "An agent is waiting on
/// you" does not stop being true when the panel retracts, and the ten-second
/// exclamation eyes have the same problem from the other end: they are built
/// to be *noticed*, and a flash you happened not to be looking at is nothing
/// at all.
///
/// So the drop retracts and leaves something behind — a small black tongue
/// hanging off the notch's bottom edge with one amber pip per stuck session.
/// It peels off as the panel goes, settles, and then **stops moving entirely**
/// until the session is dealt with. That stillness is the whole point: a thing
/// that pulsed for as long as an agent was stuck would be a hostage
/// situation, and you would learn to stop seeing it inside a week. The change
/// is the animation; the state it leaves behind is furniture.
public enum NotchTab {
    /// Past this the pips stop being countable at a glance, and "several
    /// things are stuck" is one fact rather than four. The rim is already the
    /// place that lists them individually.
    public static let maxPips = 4

    /// How much height it claims under the notch. Deliberately tiny — this is
    /// a bookmark, not a strip you read.
    public static let bodyHeight: CGFloat = 9

    public static let pipWidth: CGFloat = 14
    public static let pipHeight: CGFloat = 3
    public static let pipGap: CGFloat = 4
    /// Black either side of the pips, so the tongue reads as part of the notch
    /// rather than as a floating marker.
    public static let shoulder: CGFloat = 7

    /// How many pips for `sessions` waiting.
    public static func pips(sessions: Int) -> Int {
        min(max(sessions, 0), maxPips)
    }

    /// Width of the tongue for that many pips.
    ///
    /// Grows with the count for the same reason the rim divides itself: the
    /// question you actually have with several agents running is *how many*,
    /// and width is the only channel that can answer it while holding
    /// perfectly still.
    public static func width(sessions: Int) -> CGFloat {
        let n = pips(sessions: sessions)
        guard n > 0 else { return 0 }
        let pipsWidth = CGFloat(n) * pipWidth + CGFloat(n - 1) * pipGap
        return pipsWidth + 2 * shoulder
    }
}

/// The tongue itself.
struct NotchTabView: View {
    var sessions: Int

    static let bodyHeight = NotchTab.bodyHeight
    /// It never widens the notch; it hangs off the middle of the bottom edge.
    static let expandedWidth: CGFloat = 0

    @State private var peeled = false

    var body: some View {
        let n = NotchTab.pips(sessions: sessions)
        ZStack {
            // Overshoots upward into the panel above so the tongue and the
            // notch body are one silhouette with no seam at the join.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.black)
                .frame(width: NotchTab.width(sessions: sessions),
                       height: Self.bodyHeight + 7)
                .offset(y: -3.5)
            HStack(spacing: NotchTab.pipGap) {
                ForEach(0..<n, id: \.self) { _ in
                    Capsule(style: .continuous)
                        .fill(NotchRim.amber)
                        .frame(width: NotchTab.pipWidth, height: NotchTab.pipHeight)
                }
            }
            .offset(y: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.bodyHeight)
        // Peels off the retracting panel: squashed against the notch, then
        // springs down and settles. One motion, on arrival, and never again —
        // `peeled` is set once and nothing sets it back.
        .scaleEffect(x: 1, y: peeled ? 1 : 0.1, anchor: .top)
        .opacity(peeled ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) { peeled = true }
        }
        // A second agent getting stuck is news; the pip that appears for it
        // should arrive rather than blink into existence.
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: n)
    }
}
