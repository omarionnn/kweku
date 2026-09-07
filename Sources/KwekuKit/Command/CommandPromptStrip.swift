import SwiftUI

/// The hover affordance for the command line: one line, under the notch.
///
/// Tier one of two. Hovering the notch is a gesture you make all day — to see
/// what the agents are doing, to read the weather — and the full command panel
/// is far too much to put under every one of them. This is the invitation:
/// a prompt, the shortcut that opens it without the mouse, and nothing else.
/// Chips, output and verbs belong to `CommandView`, because they all describe
/// a command you are actually composing.
///
/// It carries the running state too, so work started here stays visible after
/// the panel is dismissed — otherwise a dispatched command would vanish the
/// moment you clicked away from it.
struct CommandPromptStrip: View {
    var busy: Bool
    /// The gateway's own status line while something is in flight.
    var label: String?
    var onOpen: () -> Void

    static let bodyHeight: CGFloat = 28
    static let expandedWidth: CGFloat = 250

    @State private var hovering = false
    /// Guards the press gesture, which otherwise fires for every drag update.
    @State private var armed = false

    var body: some View {
        content
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            // Opens on *press*, not on release. The notch's own click handler
            // is driven by an `NSEvent` monitor that can't see which view was
            // hit, so a release here also reads as "take me to the session
            // that wants me". Claiming the keyboard on the way down means that
            // release arrives with the field already open, and the tap handler
            // knows to leave it alone.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !armed else { return }
                        armed = true
                        onOpen()
                    }
                    .onEnded { _ in armed = false }
            )
            .frame(height: Self.bodyHeight)
    }

    private var content: some View {
        HStack(spacing: 7) {
                Image(systemName: busy ? "circle.dotted" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(busy ? NotchRim.amber : .white.opacity(0.45))
                Text(label ?? "ask Kweku")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(busy ? 0.85 : 0.55))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 10)
                // Named, not hidden: the point of the strip is to teach the
                // shortcut that makes the strip unnecessary.
                Text("⌥Space")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 0.4 : 0.22))
            }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Capsule().fill(Color.black.opacity(hovering ? 0.95 : 0.8)))
        .overlay(
            Capsule().stroke(Color.white.opacity(hovering ? 0.18 : 0.07), lineWidth: 0.6)
        )
    }
}
