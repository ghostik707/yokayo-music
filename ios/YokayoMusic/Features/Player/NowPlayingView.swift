import SwiftUI
import AVKit
import MediaPlayer

/// Полноэкранный плеер в стиле Apple Music.
struct NowPlayingView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var colors: [Color] = Array(repeating: Color(white: 0.2), count: 9)
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var showLab = false
    @State private var dragY: CGFloat = 0
    @State private var videoFile: URL?
    @State private var showUncensored = false

    private var song: Song? { player.current }
    private var hasVideo: Bool { videoFile != nil && settings.animatedCovers }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                LivingBackground(colors: colors).ignoresSafeArea()
                if settings.particles {
                    ParticleField(count: 28, color: .white, speed: 1).ignoresSafeArea()
                }
                if hasVideo, let videoFile {
                    LoopingVideo(url: videoFile)
                        .frame(width: geo.size.width, height: geo.size.height * 0.62)
                        .clipped()
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                        .ignoresSafeArea(edges: .top)
                        .transition(.opacity)
                }
                VStack(spacing: 0) {
                    Capsule().fill(.white.opacity(0.35)).frame(width: 38, height: 5).padding(.top, 8)
                    if showQueue {
                        compactHeader.padding(.horizontal, 28).padding(.top, 16)
                        QueueView().transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if showLyrics {
                        compactHeader.padding(.horizontal, 28).padding(.top, 16)
                        LyricsView().transition(.opacity)
                    } else {
                        if hasVideo { Spacer(minLength: 0) } else {
                            Spacer(minLength: 16)
                            artwork(width: geo.size.width - 56)
                            Spacer(minLength: 16)
                        }
                        info.padding(.horizontal, 28)
                    }
                    ScrubBar().padding(.horizontal, 28).padding(.top, 14)
                    controls.padding(.top, 18)
                    VolumeBar().padding(.horizontal, 28).padding(.top, 22)
                    bottomBar.padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 8)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .offset(y: max(0, dragY))
        .gesture(DragGesture().onChanged { dragY = $0.translation.height }.onEnded { v in
            if v.translation.height > 140 || v.predictedEndTranslation.height > 400 { dismiss() }
            else { withAnimation(.spring) { dragY = 0 } }
        })
        .task(id: song?.id) { await refreshArtwork() }
        .sheet(isPresented: $showUncensored) { if let song { UncensoredSheet(song: song) } }
        .sheet(isPresented: $showLab) {
            NavigationStack { DJLabView() }.environment(\.colorScheme, .dark).presentationDetents([.large])
        }
    }

    private func refreshArtwork() async {
        videoFile = nil
        guard let song else { return }
        if let url = song.coverURL(400), let img = await ImagePipeline.shared.image(url) {
            withAnimation(.easeInOut(duration: 0.8)) { colors = ArtworkPalette.colors(img) }
        }
        if let v = song.videoCoverURL, let file = await VideoCovers.shared.localFile(for: v), player.current?.id == song.id {
            withAnimation(.easeInOut(duration: 0.6)) { videoFile = file }
        }
    }

    private func artwork(width: CGFloat) -> some View {
        CoverView(url: song?.coverURL(800), cornerRadius: 12)
            .frame(width: width, height: width)
            .shadow(color: .black.opacity(player.isPlaying ? 0.45 : 0.25), radius: player.isPlaying ? 30 : 12, y: player.isPlaying ? 18 : 6)
            .scaleEffect(player.isPlaying ? 1 : 0.78)
            .animation(.spring(response: 0.5, dampingFraction: 0.68), value: player.isPlaying)
            .id(song?.id)
            .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
            .animation(.easeInOut(duration: 0.35), value: song?.id)
    }

    private var compactHeader: some View {
        HStack(spacing: 14) {
            CoverView(url: song?.coverURL(200), cornerRadius: 8).frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(song?.title ?? "").font(.headline).lineLimit(1)
                Text(song?.artist ?? "").foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
        }
    }

    private var info: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(song?.title ?? "Не исполняется").font(.title3.bold()).lineLimit(1)
                    if song?.explicit == true { ExplicitBadge() }
                }
                Text(song?.artist ?? "").font(.title3).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                if let s = player.djStatus {
                    Label(s, systemImage: "dial.medium.fill").font(.caption.weight(.semibold)).foregroundStyle(Color.neon)
                        .transition(.opacity)
                }
                if player.speedMode != .normal {
                    Label(player.speedMode.title, systemImage: player.speedMode.icon).font(.caption.weight(.semibold)).foregroundStyle(Color.neon)
                }
                if let s = player.sleepLabel {
                    Label(s, systemImage: "moon.zzz.fill").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            if let song, !song.isLocal {
                Button { player.toggleLike(song) } label: {
                    Image(systemName: player.liked.contains(song.id) ? "heart.fill" : "heart")
                        .font(.title3).frame(width: 34, height: 34)
                        .background(.white.opacity(0.14), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .symbolEffect(.bounce, value: player.liked.contains(song.id))
            }
            if let song {
                Menu {
                    Menu {
                        ForEach(Player.SpeedMode.allCases) { m in
                            Button { player.setSpeed(m) } label: {
                                Label(m.title, systemImage: player.speedMode == m ? "checkmark" : m.icon)
                            }
                        }
                    } label: { Label("Скорость: \(player.speedMode.title)", systemImage: player.speedMode.icon) }
                    SleepTimerMenu()
                    Button { showLab = true } label: { Label("DJ-лаборатория", systemImage: "flask") }
                    if !song.isLocal {
                        Button { showUncensored = true } label: { Label("Версия без цензуры", systemImage: "e.square") }
                    }
                    Divider()
                    SongMenu(song: song)
                } label: {
                    Image(systemName: "ellipsis").font(.title3).frame(width: 34, height: 34)
                        .background(.white.opacity(0.14), in: Circle())
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack {
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 34)) }
                .buttonStyle(PressScale())
            Spacer()
            Button { player.togglePlay() } label: {
                ZStack {
                    if player.isLoading { ProgressView().controlSize(.large).tint(.white) }
                    else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 48))
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                }.frame(width: 80, height: 70)
            }
            .buttonStyle(PressScale())
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 34)) }
                .buttonStyle(PressScale())
            Spacer()
        }
    }

    private var bottomBar: some View {
        HStack {
            Button { settings.djEnabled.toggle(); UIImpactFeedbackGenerator(style: .rigid).impactOccurred() } label: {
                Image(systemName: "dial.medium.fill").font(.title3)
                    .foregroundStyle(settings.djEnabled ? Color.neon : .white.opacity(0.6))
                    .shadow(color: settings.djEnabled ? Color.neon.opacity(0.8) : .clear, radius: 6)
            }
            Spacer()
            Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showLyrics.toggle(); showQueue = false } } label: {
                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble").font(.title3)
                    .foregroundStyle(showLyrics ? .black : .white.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .background(showLyrics ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
            }
            .disabled(song?.isLocal ?? true)
            Spacer()
            AirPlayButton().frame(width: 36, height: 36)
            Spacer()
            Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showQueue.toggle(); showLyrics = false } } label: {
                Image(systemName: "list.bullet").font(.title3)
                    .foregroundStyle(showQueue ? .black : .white.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .background(showQueue ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(.plain)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Живой фон из цветов обложки (медленно «плавающая» сетка градиента).
struct LivingBackground: View {
    let colors: [Color]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = Float(ctx.date.timeIntervalSinceReferenceDate)
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + 0.15 * sin(t * 0.3), 0], [1, 0],
                [0, 0.5 + 0.12 * cos(t * 0.25)], [0.5 + 0.2 * sin(t * 0.21), 0.5 + 0.2 * cos(t * 0.27)], [1, 0.5 + 0.12 * sin(t * 0.33)],
                [0, 1], [0.5 + 0.15 * cos(t * 0.29), 1], [1, 1],
            ], colors: colors.count == 9 ? colors : Array(repeating: .gray, count: 9))
        }
        .overlay(Color.black.opacity(0.18))
    }
}

/// Прогресс трека: тонкая полоса, которая утолщается при перетаскивании.
/// Перерисовывается только она сама, по кадрам дисплея.
struct ScrubBar: View {
    @EnvironmentObject private var player: Player
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying || dragging != nil)) { _ in
            let dur = max(player.duration, 0.01)
            let value = dragging ?? min(1, player.livePosition / dur)
            VStack(spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white.opacity(dragging != nil ? 1 : 0.75)).frame(width: max(0, g.size.width * value))
                    }
                    .frame(height: dragging != nil ? 12 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in withAnimation(.spring(response: 0.25)) { dragging = min(1, max(0, v.location.x / g.size.width)) } }
                        .onEnded { _ in
                            if let d = dragging { player.seek(to: d * player.duration) }
                            withAnimation(.spring(response: 0.3)) { dragging = nil }
                        })
                }
                .frame(height: 20)
                HStack {
                    Text(formatTime(value * player.duration))
                    Spacer()
                    Text("-" + formatTime(max(0, player.duration - value * player.duration)))
                }
                .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.white.opacity(0.55))
            }
            .scaleEffect(x: dragging != nil ? 1.03 : 1, anchor: .center)
        }
    }
}

/// Громкость системы.
struct VolumeBar: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.white.opacity(0.6))
            SystemVolumeSlider().frame(height: 30)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .white
        if let slider = v.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
            slider.setThumbImage(UIImage(), for: .normal)
        }
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.75)
        v.activeTintColor = UIColor(Color.neon)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Зацикленное видео без звука (анимированная обложка).
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var looper: AVPlayerLooper?
    }
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        let q = AVQueuePlayer()
        q.isMuted = true
        q.preventsDisplaySleepDuringVideoPlayback = false
        v.looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: url))
        (v.layer as! AVPlayerLayer).player = q
        (v.layer as! AVPlayerLayer).videoGravity = .resizeAspectFill
        q.play()
        return v
    }
    func updateUIView(_ uiView: PlayerView, context: Context) {}
}
