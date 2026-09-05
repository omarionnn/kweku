import SwiftUI

/// The caption strip under the notch during a Live session.
///
/// Live mode used to be a glow and nothing else — you could not tell whether
/// Kweku had heard you, was thinking, or had already answered. This shows the
/// two lines that answer that: what it heard, and what it's saying.
///
/// Text is tail-aligned and clipped, so a long sentence scrolls the way a
/// teleprompter does instead of wrapping the notch into a paragraph.
struct LiveCaptionView: View {
    /// What Kweku heard Omari say, and what Kweku is saying. Both are owned
    /// and cleared by `LiveSessionController` — the spoken line lives exactly
    /// as long as there is audio still playing it.
    var heard: String
    var spoken: String
    /// Speech amplitude (0…1); the leading dot rides it.
    var level: CGFloat

    static let bodyHeight: CGFloat = 40
    static let expandedWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !heard.isEmpty {
                Text(heard)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).truncationMode(.head)
            }
            if !spoken.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.7 + level * 0.9)
                        .animation(.linear(duration: 0.08), value: level)
                    Text(spoken)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1).truncationMode(.head)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .frame(height: Self.bodyHeight)
        .animation(.easeInOut(duration: 0.2), value: heard)
        .animation(.easeInOut(duration: 0.2), value: spoken)
    }
}
