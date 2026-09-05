import SwiftUI

/// Spotify island, iPhone Dynamic-Island style.
///
/// Collapsed: the black notch simply grows *wider* — same height as the cutout,
/// album art in the left wing, equalizer in the right wing, cutout in the
/// middle. Nothing hangs below; no title (exactly like the iPhone compact
/// island, whose height matches the cutout with art/waveform flanking it).
///
/// Expanded (hover): the island grows into a rounded panel that contains the
/// cutout, with art + title/artist + scrubber + transport below it.
struct NowPlayingView: View {
    @ObservedObject var music: MusicHub
    @ObservedObject var vm: NotchViewModel

    /// Width of each side wing holding art / equalizer (iPhone ears ≈ 52pt).
    static let wing: CGFloat = 48
    /// Extra lip below the menu-bar band so the pill reads as one shape.
    static let lip: CGFloat = 4
    static let expandedBody: CGFloat = 96
    static let expandedWidth: CGFloat = 360

    private var expanded: Bool { vm.isHovering || vm.expanded }

    var body: some View {
        let cutoutH = vm.notchSize.height

        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .top) {
                Color.clear
                ZStack(alignment: .top) {
                    // One wide nook: flush square top, rounded bottom. The
                    // physical cutout sits inside it — the island *contains*
                    // the notch, like the iPhone.
                    NotchPanelShape(notchWidth: w, notchHeight: 0,
                                    bottom: expanded ? 24 : 12)
                        .fill(Color.black)
                    if expanded {
                        expandedCard
                            .frame(width: w, height: Self.expandedBody)
                            .offset(y: cutoutH)
                    } else {
                        collapsedFlanks
                            .frame(width: w, height: cutoutH)
                    }
                }
                .frame(width: w, height: cutoutH + (expanded ? Self.expandedBody : Self.lip))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Collapsed — art | (cutout) | equalizer, all in the cutout band

    private var collapsedFlanks: some View {
        HStack {
            artwork(side: 21)
            Spacer(minLength: 0)              // the physical cutout lives here
            Equalizer(active: music.now.isPlaying).frame(width: 18, height: 14)
        }
        .padding(.horizontal, 13)
    }

    // MARK: Expanded

    private var expandedCard: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                artwork(side: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(music.now.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(music.now.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                transport
            }
            scrubber
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }

    private var transport: some View {
        HStack(spacing: 16) {
            control("backward.fill", size: 12) { music.previous() }
            control(music.now.isPlaying ? "pause.fill" : "play.fill", size: 15) { music.togglePlayPause() }
            control("forward.fill", size: 12) { music.next() }
        }
    }
    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size + 8, height: size + 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var scrubber: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: 3)
                    Capsule().fill(Color.white).frame(width: w * music.now.progress, height: 3)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { g in music.seek(toFraction: g.location.x / max(1, w)) })
            }
            .frame(height: 6)
            HStack {
                Text(NowPlaying.formatTime(music.now.positionSec))
                Spacer()
                Text("-" + NowPlaying.formatTime(max(0, music.now.durationSec - music.now.positionSec)))
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
        }
    }
    @ViewBuilder private func artwork(side: CGFloat) -> some View {
        Group {
            if let image = music.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack { Color.white.opacity(0.1); Image(systemName: "music.note").font(.system(size: side * 0.42)).foregroundStyle(.white.opacity(0.5)) }
            }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
    }
}

/// Audio equalizer bars; oscillate (Core-Animation-driven) while playing.
private struct Equalizer: View {
    var active: Bool
    @State private var up = false
    private let durations: [Double] = [0.42, 0.58, 0.5, 0.64]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(Color.white.opacity(0.85)).frame(width: 2.5, height: barHeight(i))
                    .animation(active ? .easeInOut(duration: durations[i]).repeatForever(autoreverses: true) : .easeOut(duration: 0.2), value: up)
            }
        }
        .onAppear { up = active }
        .onChange(of: active) { up = $0 }
    }
    private func barHeight(_ i: Int) -> CGFloat {
        let lows: [CGFloat] = [4, 6, 3, 5], highs: [CGFloat] = [12, 9, 13, 10]
        return active ? (up ? highs[i] : lows[i]) : lows[i]
    }
}
