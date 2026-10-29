import SwiftUI
import YMAPI

/// Общий экран коллекции: шапка с обложкой, «Слушать/Перемешать», список треков.
struct CollectionView: View {
    let title: String
    var subtitle: String? = nil
    var caption: String? = nil
    var coverURL: URL? = nil
    var coverSymbol = "music.note.list"
    var coverAsset: String? = nil
    var numbered = false
    var onDelete: ((Song) -> Void)? = nil
    let load: () async throws -> [Song]

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var settings: AppSettings
    @State private var allSongs: [Song] = []
    private var songs: [Song] { settings.showExplicit ? allSongs : allSongs.filter { !$0.explicit } }
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            VStack(spacing: 12) {
                Group {
                    if let coverAsset { BrandCover(asset: coverAsset) }
                    else { CoverView(url: coverURL, cornerRadius: 12, symbol: coverSymbol) }
                }
                    .frame(width: 250, height: 250)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    .padding(.top, 8)
                VStack(spacing: 4) {
                    Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                    if let subtitle { Text(subtitle).font(.title3).foregroundStyle(Color.accentColor).multilineTextAlignment(.center) }
                    if let caption { Text(caption).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase) }
                }
                .padding(.horizontal)
                PlayShuffleButtons(songs: songs).padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))

            if loading || error != nil {
                LoadState(loading: loading, error: error) { Task { await reload() } }.listRowSeparator(.hidden).listRowBackground(Color.clear)
            }

            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                TrackRow(song: song, number: i + 1, showCover: !numbered)
                    .onTapGesture { player.play(songs, startAt: i) }
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.08))
            }
            .onDelete(perform: onDelete == nil ? nil : { idx in
                let removed = idx.map { songs[$0] }
                removed.forEach { onDelete?($0) }
                allSongs.removeAll { s in removed.contains(s) }
            })

            if !songs.isEmpty {
                let minutes = songs.reduce(0) { $0 + $1.durationMs } / 60000
                Text("\(songs.count) \(plural(songs.count, "трек", "трека", "треков")), \(minutes) мин.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
            }
        }
        .listStyle(.plain)
        .yokayoBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { library.download(songs) } label: { Label("Загрузить всё в приложение", systemImage: "arrow.down.circle") }
                    Button { songs.reversed().forEach(player.playNext) } label: { Label("Воспроизвести далее", systemImage: "text.line.first.and.arrowtriangle.forward") }
                } label: { Image(systemName: "ellipsis") }
                .disabled(songs.isEmpty)
            }
        }
        .task { if allSongs.isEmpty { await reload() } }
        .refreshable { await reload() }
    }

    private func reload() async {
        loading = allSongs.isEmpty; error = nil
        do { allSongs = try await load() } catch { self.error = "Проверь интернет и попробуй ещё раз." }
        loading = false
    }
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    if n10 == 1 && n100 != 11 { return one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
    return many
}

struct PlaylistView: View {
    let uid: Int
    let kind: Int
    let title: String
    var coverURL: URL?
    var subtitle: String?

    var body: some View {
        CollectionView(title: title, subtitle: subtitle, caption: "Плейлист", coverURL: coverURL) {
            let p = try await API.playlist(uid: uid, kind: kind)
            return try await API.songs(of: p)
        }
    }
}

extension PlaylistView {
    init(_ p: Playlist) {
        self.init(uid: p.owner?.uid ?? p.uid ?? 0, kind: p.kind ?? 0, title: p.title, coverURL: p.coverURL,
                  subtitle: p.owner?.name ?? p.owner?.login)
    }
}

struct AlbumView: View {
    let albumId: Int
    @State private var album: Album?

    var body: some View {
        CollectionView(title: album?.title ?? " ", subtitle: album?.artistLine,
                       caption: [album?.genre, album?.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                       coverURL: album?.coverURL(600), numbered: true) {
            let a = try await API.album(albumId)
            await MainActor.run { album = a }
            return (a.volumes ?? []).flatMap { $0 }.map(Song.init(track:))
        }
    }
}

struct LikedSongsView: View {
    var body: some View {
        CollectionView(title: "Мне нравится", caption: "Ваша коллекция", coverAsset: "Star") {
            try await API.likedSongs()
        }
    }
}

/// Фирменная обложка: звезда Yokayo на неоновом фоне.
struct BrandCover: View {
    var asset = "Star"
    var symbol: String? = "heart.fill"
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.04, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.neonDeep.opacity(0.7), .clear], center: .center, startRadius: 0, endRadius: 140)
            Image(asset).resizable().scaledToFit().padding(26)
                .shadow(color: Color.neon.opacity(0.8), radius: 20)
            if let symbol {
                Image(systemName: symbol).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .padding(10).background(.ultraThinMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(12)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.neon.opacity(0.35), lineWidth: 0.8))
    }
}

/// Свой плейлист Yokayo.
struct LocalPlaylistView: View {
    let id: String
    @EnvironmentObject private var library: LocalLibrary
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let p = library.playlist(id)
        CollectionView(title: p?.name ?? "Плейлист", caption: "Плейлист Yokayo", coverURL: p?.coverURL,
                       onDelete: { library.removeSong($0, from: id) }) {
            library.playlist(id)?.songs ?? []
        }
        .id(p?.songs.count ?? 0)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newName = p?.name ?? ""; renaming = true } label: { Image(systemName: "pencil") }
            }
        }
        .alert("Название плейлиста", isPresented: $renaming) {
            TextField("Название", text: $newName)
            Button("Сохранить") { library.renamePlaylist(id, to: newName) }
            Button("Отмена", role: .cancel) {}
        }
    }
}
