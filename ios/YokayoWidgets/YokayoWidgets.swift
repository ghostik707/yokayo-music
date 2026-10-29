import WidgetKit
import SwiftUI
import AppIntents

private let neon = Color(red: 0.36, green: 0.72, blue: 1.0)
private let neonDeep = Color(red: 0.16, green: 0.38, blue: 1.0)

@main
struct YokayoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        WaveWidget()
        WaveControl()
    }
}

// MARK: - Данные

struct PlayerEntry: TimelineEntry {
    let date: Date
    let state: WidgetState?
    let artwork: UIImage?
}

struct PlayerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlayerEntry {
        PlayerEntry(date: .now, state: WidgetState(title: "Моя волна", artist: "Yokayo", isPlaying: false, djStatus: nil, hasArtwork: false, trackId: ""), artwork: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (PlayerEntry) -> Void) { completion(current()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlayerEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))   // приложение само просит обновить
    }
    private func current() -> PlayerEntry {
        let state = SharedStore.load()
        let art = state?.hasArtwork == true ? SharedStore.artworkData().flatMap(UIImage.init(data:)) : nil
        return PlayerEntry(date: .now, state: state, artwork: art)
    }
}

// MARK: - Сейчас играет

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "nowplaying", provider: PlayerProvider()) { entry in
            NowPlayingView(entry: entry)
        }
        .configurationDisplayName("Сейчас играет")
        .description("Трек, обложка и управление плеером.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct NowPlayingView: View {
    let entry: PlayerEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .systemMedium: medium
            default: small
            }
        }
        .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var background: some View {
        if family == .accessoryCircular || family == .accessoryRectangular {
            AccessoryWidgetBackground()
        } else if let art = entry.artwork {
            ZStack {
                Image(uiImage: art).resizable().scaledToFill().blur(radius: 26).scaleEffect(1.3)
                Color.black.opacity(0.35)
            }
        } else {
            LinearGradient(colors: [Color(red: 0.02, green: 0.04, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
        }
    }

    private var title: String { entry.state?.title ?? "Открой Yokayo" }
    private var artist: String { entry.state?.artist ?? "и включи музыку" }
    private var playing: Bool { entry.state?.isPlaying ?? false }

    private var cover: some View {
        Group {
            if let art = entry.artwork { Image(uiImage: art).resizable().scaledToFill() }
            else { ZStack { Color.black; Image("Star").resizable().scaledToFit().padding(10) } }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                cover.frame(width: 56, height: 56)
                Spacer()
                Image("Star").resizable().scaledToFit().frame(width: 18, height: 18)
            }
            Spacer(minLength: 0)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(artist).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            HStack(spacing: 14) {
                Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                Button(intent: TogglePlaybackIntent()) { Image(systemName: playing ? "pause.fill" : "play.fill") }
                Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
            }
            .font(.system(size: 15, weight: .bold))
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .foregroundStyle(.white)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            cover.frame(width: 118, height: 118).shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image("Star").resizable().scaledToFit().frame(width: 16, height: 16)
                    Text(playing ? "СЕЙЧАС ИГРАЕТ" : "YOKAYO").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.7))
                }
                Text(title).font(.headline).lineLimit(2)
                Text(artist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                if let dj = entry.state?.djStatus {
                    Text(dj).font(.caption2.weight(.semibold)).foregroundStyle(neon).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 22) {
                    Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                    Button(intent: TogglePlaybackIntent()) { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 22, weight: .bold)) }
                    Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                }
                .font(.system(size: 17, weight: .bold))
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: playing ? "waveform" : "music.note").font(.title3)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline).lineLimit(1)
                Text(artist).font(.caption).lineLimit(1)
            }
        }
        .widgetAccentable()
    }

    private var circular: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.title2.weight(.bold))
        }
        .buttonStyle(.plain)
        .widgetAccentable()
    }
}

// MARK: - Моя волна

struct WaveWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "wave", provider: PlayerProvider()) { _ in
            WaveView()
        }
        .configurationDisplayName("Моя волна")
        .description("Запуск «Моей волны» одним нажатием.")
        .supportedFamilies([.systemSmall])
    }
}

struct WaveView: View {
    var body: some View {
        Button(intent: PlayWaveIntent()) {
            VStack(alignment: .leading, spacing: 4) {
                Image("Star").resizable().scaledToFit().frame(width: 64, height: 64)
                    .shadow(color: neon.opacity(0.9), radius: 14)
                Spacer(minLength: 0)
                Text("МОЯ ВОЛНА").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.7))
                Label("Слушать", systemImage: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) {
            ZStack {
                LinearGradient(colors: [neonDeep, .black], startPoint: .topTrailing, endPoint: .bottomLeading)
                RadialGradient(colors: [neon.opacity(0.55), .clear], center: .topLeading, startRadius: 0, endRadius: 120)
            }
        }
    }
}

// MARK: - Пункт управления

struct WaveControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.yokayo.music.wave-control") {
            ControlWidgetButton(action: PlayWaveIntent()) {
                Label("Моя волна", systemImage: "sparkle")
            }
        }
        .displayName("Моя волна")
        .description("Запустить «Мою волну» в Yokayo")
    }
}
