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
///
/// Colour comes from the record. Everything used to be white on black, which
/// looked the same for every track; the accent `MusicHub` pulls out of the
/// cover now drives the progress fill, the equalizer and the notch rim, so the
/// island takes on the album you're playing.
struct NowPlayingView: View {
    @ObservedObject var music: MusicHub
    @ObservedObject var vm: NotchViewModel
    var rim: NotchRimStyle
    /// The critter rides in the collapsed island's right wing, so music and
    /// the creature can be enjoyed at once. Expanded, the card takes over and
    /// the agent panel stacks below instead.
    @ObservedObject var critter: CreatureState

    @State private var artGlow = false
    /// Width of each side wing holding art / equalizer (iPhone ears ≈ 52pt).
    static let wing: CGFloat = 48
    /// Extra lip below the menu-bar band so the pill reads as one shape.
    static let lip: CGFloat = 4
    static let expandedBody: CGFloat = 96
    static let expandedWidth: CGFloat = 360

    @Namespace private var art
    /// Fraction being dragged right now; overrides the clock while held.
    @State private var scrubbing: Double?
    @State private var scrubHovering = false

    private var expanded: Bool { vm.isHovering || vm.expanded }

    /// Album accent, or white for greyscale covers.
    private var accent: Color { music.accent.map(Color.init) ?? .white }

    /// Music's own ambient rim, used only when nothing more urgent is on it —
    /// an agent waiting for you outranks a pretty colour.
    private var effectiveRim: NotchRimStyle {
        if case .none = rim, let colour = music.accent {
            return .album(colour: Color(colour), playing: music.now.isPlaying)
        }
        return rim
    }

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
                    NotchRim(notchWidth: w, notchHeight: 0,
                             bottom: expanded ? 24 : 12, style: effectiveRim)
                    if expanded {
                        expandedCard
                            .frame(width: w, height: Self.expandedBody)
                            .offset(y: cutoutH)
                            .transition(.opacity)
                    } else {
                        collapsedFlanks
                            .frame(width: w, height: cutoutH)
                            .transition(.opacity)
                    }
                }
                .frame(width: w, height: cutoutH + (expanded ? Self.expandedBody : Self.lip))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The container used to morph while its contents hard-cut. Now the art
        // travels between the two layouts and the rest cross-fades over it.
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: expanded)
        .animation(.easeInOut(duration: 0.3), value: music.accent)
    }

    // MARK: Collapsed — art | (cutout) | equalizer, all in the cutout band

    private var collapsedFlanks: some View {
        HStack {
            // Art with a breathing accent glow while playing.
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent)
                    .frame(width: 25, height: 25)
                    .blur(radius: 5)
                    .opacity(music.now.isPlaying ? (artGlow ? 0.85 : 0.35) : 0)
                artwork(side: 21)
            }
            .onAppear { startArtGlow() }
            .onChange(of: music.now.isPlaying) { _ in startArtGlow() }
            Spacer(minLength: 0)              // the physical cutout lives here
            CritterFace(state: critter, vm: vm, showMotes: false)
                .scaleEffect(0.7)
                .frame(width: 30, height: 24)
        }
        .padding(.horizontal, 13)
    }

    private func startArtGlow() {
        artGlow = false
        guard music.now.isPlaying else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            artGlow = true
        }
    }

    // MARK: Expanded

    private var expandedCard: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                artwork(side: 44)
                VStack(alignment: .leading, spacing: 2) {
                    // Track names run long ("… (feat. X) - Remastered 2011"),
                    // so the title scrolls instead of being cut off.
                    Marquee(text: music.now.title, active: expanded)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(music.now.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
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
            control(music.now.isPlaying ? "pause.fill" : "play.fill", size: 15) {
                music.togglePlayPause()
            }
            control("forward.fill", size: 12) { music.next() }
        }
    }

    private func control(_ symbol: String, size: CGFloat,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 8, height: size + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
    }

    // MARK: Scrubber

    /// Live position: the drag wins while you hold it, otherwise the clock
    /// interpolates forward from the last poll so the bar glides instead of
    /// ticking once a second.
    private func fraction(at now: Date) -> Double {
        scrubbing ?? music.clock.progress(at: now)
    }

    private var scrubber: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: !music.now.isPlaying && scrubbing == nil)) { context in
            let f = fraction(at: context.date)
            let elapsed = f * music.now.durationSec
            let active = scrubbing != nil || scrubHovering
            VStack(spacing: 3) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                            .frame(height: active ? 5 : 3)
                        Capsule().fill(accent)
                            .frame(width: w * f, height: active ? 5 : 3)
                        // Thumb only while you're near it — the bar stays a
                        // clean line the rest of the time.
                        Circle()
                            .fill(accent)
                            .frame(width: 9, height: 9)
                            .offset(x: w * f - 4.5)
                            .opacity(active ? 1 : 0)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                    }
                    .frame(height: geo.size.height, alignment: .center)
                    // A 3pt line is a mean click target; take the whole strip.
                    .contentShape(Rectangle())
                    .onHover { scrubHovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                scrubbing = min(1, max(0, g.location.x / max(1, w)))
                            }
                            .onEnded { g in
                                let target = min(1, max(0, g.location.x / max(1, w)))
                                music.seek(toFraction: target)
                                scrubbing = nil
                            }
                    )
                    .animation(.easeOut(duration: 0.15), value: active)
                }
                .frame(height: 14)
                HStack {
                    Text(NowPlaying.formatTime(elapsed))
                    Spacer()
                    Text("-" + NowPlaying.formatTime(max(0, music.now.durationSec - elapsed)))
                }
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(scrubbing != nil ? 0.8 : 0.45))
            }
        }
    }

    // MARK: Artwork

    @ViewBuilder private func artwork(side: CGFloat) -> some View {
        Group {
            if let image = music.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.42))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
        // Covers used to swap instantly on a track change; now one fades out
        // under the next as it settles in.
        .id(music.now.trackID)
        .transition(.opacity.combined(with: .scale(scale: 1.08)))
        .animation(.easeInOut(duration: 0.28), value: music.now.trackID)
        .matchedGeometryEffect(id: "album-art", in: art)
    }
}

/// Press and hover feedback. `.plain` left the transport visually dead — no
/// hover, no press — which read as decoration rather than buttons.
private struct TransportButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : (hovering ? 1 : 0.82)))
            .scaleEffect(configuration.isPressed ? 0.86 : (hovering ? 1.08 : 1))
            .animation(.spring(response: 0.22, dampingFraction: 0.7),
                       value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Horizontally scrolling text, for titles too long to fit.
///
/// Only scrolls when it actually overflows — short titles sit still rather than
/// twitching. The offset is a pure function of the clock (same reasoning as the
/// notch rim's comet) so it can't drift out of phase with itself, and the text
/// is drawn twice with a gap so the wrap is seamless. Edges fade rather than
/// hard-clipping.
struct Marquee: View {
    var text: String
    /// Scroll only while the panel is open; a collapsed island shouldn't animate.
    var active: Bool
    var speed: Double = 26          // points per second
    var gap: CGFloat = 44

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var overflowing: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { geo in
            Group {
                if overflowing && active {
                    let span = textWidth + gap
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let offset = CGFloat((t * speed)
                            .truncatingRemainder(dividingBy: Double(span)))
                        HStack(spacing: gap) {
                            Text(text).fixedSize()
                            Text(text).fixedSize()
                        }
                        .offset(x: -offset)
                    }
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.04),
                                    .init(color: .black, location: 0.92),
                                    .init(color: .clear, location: 1)],
                            startPoint: .leading, endPoint: .trailing)
                    )
                } else {
                    Text(text).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { containerWidth = $0 }
        }
        .frame(height: 16)
        // Measure the laid-out string off-screen to decide whether it overflows.
        .background(
            Text(text).fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: MarqueeWidthKey.self, value: g.size.width)
                })
                .hidden()
        )
        .onPreferenceChange(MarqueeWidthKey.self) { textWidth = $0 }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
