import SwiftUI
import YMAPI

@MainActor
final class HomeModel: ObservableObject {
    @Published var dayPlaylists: [Playlist] = []
    @Published var releases: [Album] = []
    @Published var chart: [Song] = []
    @Published var loading = false
    @Published var error: String?

    func load() async {
        loading = dayPlaylists.isEmpty && releases.isEmpty
        error = nil
        async let feed = try? API.feed()
        async let rel = try? API.newReleases()
        async let ch = try? API.chart()
        let (f, r, c) = await (feed, rel, ch)
        dayPlaylists = (f?.generatedPlaylists ?? []).compactMap(\.data)
        releases = r ?? []
        chart = Array((c ?? []).prefix(20))
        if f == nil && r == nil && c == nil { error = "Не удалось загрузить главную." }
        loading = false
    }
}

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LocalLibrary
    @StateObject private var model = HomeModel()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if !session.isLoggedIn {
                        LoginPromptCard().padding(.horizontal, 20)
                    } else {
                        WaveCard().padding(.horizontal, 20)
                        LoadState(loading: model.loading, error: model.error) { Task { await model.load() } }
                        if !model.dayPlaylists.isEmpty {
                            carousel("Собрано для вас", model.dayPlaylists) { p in
                                NavigationLink { PlaylistView(p) } label: {
                                    MediaCard(url: p.coverURL, title: p.title, subtitle: "Обновляется регулярно", width: 180)
                                }
                            }
                        }
                        if !model.chart.isEmpty { ChartGrid(title: "Чарт", songs: model.chart) }
                        if !model.releases.isEmpty {
                            carousel("Новые релизы", model.releases) { a in
                                NavigationLink { AlbumView(albumId: a.id ?? 0) } label: {
                                    MediaCard(url: a.coverURL(), title: a.title ?? "", subtitle: a.artistLine)
                                }
                            }
                        }
                    }
                    if !library.mySongs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle("Моя музыка") { MyMusicView() }
                            ForEach(library.mySongs.prefix(4)) { s in
                                TrackRow(song: s).padding(.horizontal, 20)
                                    .onTapGesture { player.play(library.mySongs, startAt: library.mySongs.firstIndex(of: s) ?? 0) }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .yokayoBackground()
            .navigationTitle("Главная")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                        .accessibilityLabel("Настройки")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task(id: session.isLoggedIn) { if session.isLoggedIn { await model.load() } }
            .refreshable { await model.load() }
        }
    }

    private func carousel<T, Content: View>(_ title: String, _ items: [T], @ViewBuilder content: @escaping (T) -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in content(item).buttonStyle(.plain) }
                }
                .padding(.horizontal, 20)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// Большая карточка «Моя волна»: неоновые волны живут сами и пульсируют в такт,
/// при нажатии звезда делает оборот и от неё расходится ударная волна с искрами.
struct WaveCard: View {
    @EnvironmentObject private var player: Player
    @State private var tapAt: Date?
    @State private var spin = 0.0
    @State private var pop = false
    private var playing: Bool { player.isWave && player.isPlaying }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            tapAt = Date()
            withAnimation(.spring(response: 0.9, dampingFraction: 0.55)) { spin += 360 }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.4)) { pop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.spring(response: 0.5)) { pop = false } }
            if playing { player.togglePlay() } else { player.playWave() }
        } label: {
            GeometryReader { g in
                let star = CGPoint(x: g.size.width * 0.8, y: g.size.height * 0.33)
                ZStack(alignment: .bottomLeading) {
                    LivingBackground(colors: [.neonDeep, .black, .neon, .black, .neonDeep, .indigo, .neon, .black, .neonDeep])
                    WaveLines(playing: playing, tapAt: tapAt, star: star)
                    GlowingStar(size: 120)
                        .rotationEffect(.degrees(spin))
                        .scaleEffect(pop ? 1.25 : 1)
                        .position(star)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("МОЯ ВОЛНА").font(.caption.weight(.heavy)).foregroundStyle(.white.opacity(0.7))
                        Text("Бесконечный поток\nпод твой вкус").font(.title2.bold()).foregroundStyle(.white)
                        HStack(spacing: 8) {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                            Text(player.isWave && player.isLoading ? "Настраиваю…" : playing ? "Играет" : "Слушать")
                            if playing {
                                Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.white, in: Capsule()).foregroundStyle(.black)
                        .padding(.top, 6)
                    }
                    .padding(20)
                }
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(
                AngularGradient(colors: [.neon.opacity(0.8), .clear, .neonDeep.opacity(0.8), .clear, .neon.opacity(0.8)],
                                center: .center, angle: .degrees(spin)), lineWidth: 1.2))
            .shadow(color: Color.neonDeep.opacity(playing ? 0.6 : 0.35), radius: playing ? 26 : 18, y: 8)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(playing ? "Пауза «Моей волны»" : "Слушать «Мою волну»")
    }
}

/// Неоновые волны на карточке. Пока играет волна — дышат в такт треку.
private struct WaveLines: View {
    let playing: Bool
    let tapAt: Date?
    let star: CGPoint
    @EnvironmentObject private var player: Player

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let beat: Double = {
                guard playing, let a = player.activeDeck.analysis else { return 0 }
                return exp(-a.beatPhase(player.livePosition) * 5)        // удар в начале каждой доли
            }()
            let sinceTap = tapAt.map { ctx.date.timeIntervalSince($0) } ?? 99
            Canvas(opaque: false, rendersAsynchronously: true) { gc, size in
                let surge = sinceTap < 1.6 ? (1 - sinceTap / 1.6) : 0
                // волны
                for i in 0..<5 {
                    let k = Double(i)
                    let amp = 9 + 5 * k + 14 * beat + 40 * surge * surge
                    let speed = (playing ? 1.4 : 0.6) + 0.15 * k
                    var p = Path()
                    let baseY = size.height * (0.52 + 0.09 * k)
                    for x in stride(from: 0.0, through: Double(size.width), by: 4) {
                        let y = baseY + amp * sin(x / (70 + 18 * k) + t * speed + k * 1.3)
                            + amp * 0.35 * sin(x / 31 - t * speed * 1.7)
                        if x == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    gc.stroke(p, with: .linearGradient(Gradient(colors: [.clear, Color.neon.opacity(0.55 - 0.08 * k), Color.neonDeep.opacity(0.5), .clear]),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                              lineWidth: 1.4 + (i == 0 ? beat * 1.5 : 0))
                }
                // ударная волна и искры после нажатия
                if sinceTap < 1.2 {
                    let e = sinceTap / 1.2
                    for r in 0..<3 {
                        let rr = e * 420 * (1 + Double(r) * 0.3)
                        let a = (1 - e) * (0.8 - 0.2 * Double(r))
                        gc.stroke(Path(ellipseIn: CGRect(x: star.x - rr, y: star.y - rr, width: rr * 2, height: rr * 2)),
                                  with: .color(Color.neon.opacity(a)), lineWidth: 3 * (1 - e) + 0.5)
                    }
                    for s in 0..<18 {
                        let ang = Double(s) / 18 * 2 * .pi + Double(s % 3) * 0.2
                        let d = 30 + e * (160 + Double(s % 4) * 40)
                        let pt = CGPoint(x: star.x + cos(ang) * d, y: star.y + sin(ang) * d)
                        let sz = 4 * (1 - e) + 1
                        gc.fill(Path(ellipseIn: CGRect(x: pt.x - sz, y: pt.y - sz, width: sz * 2, height: sz * 2)),
                                with: .color(.white.opacity(1 - e)))
                    }
                }
                // мерцающие точки вокруг звезды
                for s in 0..<10 {
                    let ang = t * (playing ? 0.9 : 0.35) + Double(s) / 10 * 2 * .pi
                    let d = 86 + 8 * sin(t * 1.3 + Double(s)) + 10 * beat
                    let pt = CGPoint(x: star.x + cos(ang) * d, y: star.y + sin(ang) * d * 0.55)
                    let sz = 1.4 + 0.8 * sin(t * 2 + Double(s))
                    gc.fill(Path(ellipseIn: CGRect(x: pt.x - sz, y: pt.y - sz, width: sz * 2, height: sz * 2)),
                            with: .color(.white.opacity(0.7)))
                }
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// Сетка треков как «Лучшие песни» в Apple Music: колонки по 4, листаются вбок.
struct ChartGrid: View {
    let title: String
    let songs: [Song]
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title) { CollectionView(title: title, caption: "Топ сейчас", coverSymbol: "chart.line.uptrend.xyaxis") { songs } }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 4), count: 4), spacing: 16) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 10) {
                            CoverView(url: s.coverURL(100), cornerRadius: 5).frame(width: 48, height: 48)
                            Text("\(i + 1)").font(.headline).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).lineLimit(1)
                                Text(s.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(width: 300)
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(songs, startAt: i) }
                        .contextMenu { SongMenu(song: s) }
                    }
                }
                .padding(.horizontal, 20)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct LoginPromptCard: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var show = false
    var body: some View {
        VStack(spacing: 14) {
            GlowingStar(size: 80)
            Text("Подключи Яндекс").font(.title3.bold())
            Text("Чтобы слушать каталог, «Мою волну» и свои плейлисты, войди с Яндекс ID.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Войти") { show = true }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(24).frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .sheet(isPresented: $show) { LoginSheet {} }
    }
}
