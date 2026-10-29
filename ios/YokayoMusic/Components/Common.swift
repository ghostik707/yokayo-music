import SwiftUI
import YMAPI

extension Color {
    static let neon = Color(red: 0.36, green: 0.72, blue: 1.0)
    static let neonDeep = Color(red: 0.16, green: 0.38, blue: 1.0)
}

/// Значок «E» — трек 18+.
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Color(.systemBackground))
            .frame(width: 13, height: 13)
            .background(.secondary, in: RoundedRectangle(cornerRadius: 2.5))
    }
}

/// Заголовок секции как в Apple Music: жирный текст и шеврон.
struct SectionTitle<Destination: View>: View {
    let title: String
    var destination: Destination?

    init(_ title: String, @ViewBuilder destination: () -> Destination) {
        self.title = title; self.destination = destination()
    }

    var body: some View {
        Group {
            if let destination {
                NavigationLink { destination } label: { label(chevron: true) }.buttonStyle(.plain)
            } else { label(chevron: false) }
        }
        .padding(.horizontal, 20)
    }

    private func label(chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.title2.bold())
            if chevron { Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary) }
            Spacer()
        }
    }
}

extension SectionTitle where Destination == EmptyView {
    init(_ title: String) { self.title = title; self.destination = nil }
}

/// Карточка альбома/плейлиста для каруселей.
struct MediaCard: View {
    let url: URL?
    let title: String
    let subtitle: String?
    var width: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(url: url, cornerRadius: 10, symbol: "music.note.list")
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Строка трека.
struct TrackRow: View {
    let song: Song
    var number: Int? = nil
    var showCover = true
    @EnvironmentObject private var player: Player

    var isCurrent: Bool { player.current?.id == song.id }

    var body: some View {
        HStack(spacing: 12) {
            if let number, !showCover {
                Group {
                    if isCurrent { NowPlayingBars(animating: player.isPlaying).frame(width: 14, height: 12) }
                    else { Text("\(number)").foregroundStyle(.secondary) }
                }
                .font(.body.monospacedDigit()).frame(width: 24)
            }
            if showCover {
                CoverView(url: song.coverURL(100), cornerRadius: 5)
                    .frame(width: 48, height: 48)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35))
                            NowPlayingBars(animating: player.isPlaying).frame(width: 16, height: 14).foregroundStyle(.white)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1).foregroundStyle(isCurrent ? Color.accentColor : .primary)
                HStack(spacing: 4) {
                    if song.explicit { ExplicitBadge() }
                    Text(song.artist).lineLimit(1)
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu { SongMenu(song: song) } label: {
                Image(systemName: "ellipsis").foregroundStyle(.primary).frame(width: 30, height: 40).contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
        .contextMenu { SongMenu(song: song) } preview: {
            VStack(alignment: .leading) {
                CoverView(url: song.coverURL(400), cornerRadius: 0).frame(width: 260, height: 260)
                Text(song.title).font(.headline).padding(.horizontal)
                Text(song.artist).foregroundStyle(.secondary).padding([.horizontal, .bottom])
            }.frame(width: 260)
        }
    }
}

/// Меню трека: очередь, лайк, загрузка, поделиться.
struct SongMenu: View {
    let song: Song
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LocalLibrary

    var body: some View {
        Button { player.playNext(song) } label: { Label("Воспроизвести далее", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue(song) } label: { Label("В конец очереди", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Menu {
            Button { let p = library.createPlaylist("Новый плейлист"); library.add([song], to: p.id); player.toast = "Создан плейлист" } label: {
                Label("Новый плейлист", systemImage: "plus")
            }
            if !library.playlists.isEmpty {
                Section("Yokayo") {
                    ForEach(library.playlists) { p in
                        Button(p.name) { library.add([song], to: p.id); player.toast = "Добавлено в «\(p.name)»" }
                    }
                }
            }
            if !song.isLocal, !library.yandexPlaylists.isEmpty {
                Section("Яндекс Музыка") {
                    ForEach(library.yandexPlaylists) { p in
                        Button(p.title) { Task { player.toast = await library.addToYandex(song, playlist: p) } }
                    }
                }
            }
        } label: { Label("Добавить в плейлист", systemImage: "text.badge.plus") }
        Divider()
        if !song.isLocal {
            Button { player.playWave(seed: song) } label: { Label("Волна по этому треку", systemImage: "dot.radiowaves.left.and.right") }
            let liked = player.liked.contains(song.id)
            Button { player.toggleLike(song) } label: { Label(liked ? "Убрать из «Мне нравится»" : "Мне нравится", systemImage: liked ? "heart.slash" : "heart") }
            if library.isOffline(song) {
                Button(role: .destructive) { library.remove(song) } label: { Label("Удалить загрузку", systemImage: "trash") }
            } else {
                Button { library.download([song]) } label: { Label("Загрузить в приложение", systemImage: "arrow.down.circle") }
            }
            if let url = song.shareURL {
                ShareLink(item: url, subject: Text(song.title), message: Text("\(song.title) — \(song.artist)")) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
            }
            if let id = song.artistId {
                NavigationLink { ArtistView(artistId: id, name: song.artist) } label: { Label("К артисту", systemImage: "music.microphone") }
            }
            if let id = song.albumId {
                NavigationLink { AlbumView(albumId: id) } label: { Label("К альбому", systemImage: "square.stack") }
            }
        } else {
            Button(role: .destructive) { library.remove(song) } label: { Label("Удалить из «Моей музыки»", systemImage: "trash") }
        }
    }
}

/// Анимированные «эквалайзерные» полоски текущего трека.
struct NowPlayingBars: View {
    var animating: Bool
    var body: some View {
        TimelineView(.animation(paused: !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { i in
                    Capsule().frame(maxHeight: .infinity)
                        .scaleEffect(y: animating ? 0.3 + 0.7 * abs(sin(t * (3 + Double(i)) + Double(i))) : 0.3, anchor: .bottom)
                }
            }
        }
        .foregroundStyle(Color.accentColor)
    }
}

/// Кнопки «Слушать» и «Перемешать».
struct PlayShuffleButtons: View {
    let songs: [Song]
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 14) {
            button("Слушать", "play.fill") { player.play(songs) }
            button("Перемешать", "shuffle") { player.play(songs, shuffle: true) }
        }
        .disabled(songs.isEmpty)
        .padding(.horizontal, 20)
    }

    private func button(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

/// Индикатор загрузки и ошибки в одном месте.
struct LoadState: View {
    let loading: Bool
    let error: String?
    var retry: () -> Void
    var body: some View {
        if loading { ProgressView().frame(maxWidth: .infinity).padding(40) }
        else if let error {
            ContentUnavailableView {
                Label("Не загрузилось", systemImage: "wifi.exclamationmark")
            } description: { Text(error) } actions: {
                Button("Повторить", action: retry).buttonStyle(.bordered)
            }
        }
    }
}

extension Playlist {
    var coverURL: URL? {
        if let uri = cover?.uri { return YM.imageURL(uri, size: 400) }
        if let first = cover?.itemsUri?.first { return YM.imageURL(first, size: 400) }
        return YM.imageURL(ogImage, size: 400)
    }
}

extension Album {
    func coverURL(_ size: Int = 400) -> URL? { YM.imageURL(coverUri, size: size) }
    var artistLine: String { (artists ?? []).map(\.artistName).joined(separator: ", ") }
}

extension Artist {
    func coverURL(_ size: Int = 400) -> URL? { YM.imageURL(cover?.uri ?? ogImage, size: size) }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}
