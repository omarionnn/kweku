import SwiftUI

/// The held-item shelf shown below the notch on hover: a fanned stack of
/// draggable thumbnails with a count badge.
struct ShelfView: View {
    @ObservedObject var store: ShelfStore

    private let thumb: CGFloat = 40
    private let fan: CGFloat = 26   // horizontal step between stacked cards
    private let maxVisible = 5

    var body: some View {
        let visible = Array(store.items.prefix(maxVisible))
        let stackWidth = thumb + CGFloat(max(0, visible.count - 1)) * fan

        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .leading) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                    ShelfThumb(item: item, store: store)
                        .frame(width: thumb, height: thumb)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: CGFloat(index) * fan)
                        // No `.contextMenu` here — the thumbnail is an AppKit
                        // view that receives the right-click itself, and it
                        // serves its own Remove menu (see `ShelfThumb`).
                }
            }
            .frame(width: stackWidth, height: thumb, alignment: .leading)

            if store.items.count > 0 {
                Text("\(store.items.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 6, y: -6)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
