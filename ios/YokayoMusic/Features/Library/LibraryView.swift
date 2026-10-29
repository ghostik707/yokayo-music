import SwiftUI
import YMAPI
import UniformTypeIdentifiers

/// Медиатека как в Apple Music: разделы, свои плейлисты, плейлисты Яндекса.
struct LibraryView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var library: LocalLibrary
    @State private var playlists: [Playlist] = []
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if session.isLoggedIn {
                        row("Мне нравится", "heart.fill") { LikedSongsView() }
                        row("Плейлисты", "music.note.list") { PlaylistsListView() }
                        row("Артисты", "music.microphone") { ArtistsListView() }
                    }
                    row("Моя музыка", "folder.fill") { MyMusicView() }
                    row("Статистика", "chart.bar.fill") { StatsView() }
                    row("Загружено", "arrow.down.circle.fill") {
                        CollectionView(title: "Загружено", caption: "Доступно без интернета", coverSymbol: "arrow.down.circle",
                                       onDelete: { library.remove($0) }) { library.offlineSongs }
                    }
                }

                Section {
                    Button { newName = ""; creating = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(Color.neon)
                                .frame(width: 56, height: 56)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text("Новый плейлист").foregroundStyle(Color.neon)
                        }
                    }
                    .clearRow()
                    ForEach(library.playlists) { p in
                        NavigationLink { LocalPlaylistView(id: p.id) } label: {
                            HStack(spacing: 14) {
                                Group {
                                    if p.coverURL == nil { BrandCover(symbol: nil) } else { CoverView(url: p.coverURL, cornerRadius: 8) }
                                }.frame(width: 56, height: 56)
                                VStack(alignment: .leading) {
                                    Text(p.name).lineLimit(1)
                                    Text("\(p.songs.count) \(plural(p.songs.count, "трек", "трека", "треков"))").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .clearRow()
                    }
                    .onDelete { idx in idx.map { library.playlists[$0].id }.forEach(library.deletePlaylist) }
                } header: { header("Мои плейлисты") }

                if !playlists.isEmpty {
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 18) {
                            ForEach(playlists, id: \.playlistId) { p in
                                NavigationLink { PlaylistView(p) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CoverView(url: p.coverURL, cornerRadius: 10, symbol: "music.note.list")
                                        Text(p.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text("\(p.trackCount ?? 0) \(plural(p.trackCount ?? 0, "трек", "трека", "треков"))")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        .listRowSeparator(.hidden)
                        .clearRow()
                    } header: { header("Плейлисты Яндекса") }
                }
            }
            .listStyle(.plain)
            .yokayoBackground()
            .navigationTitle("Медиатека")
            .alert("Новый плейлист", isPresented: $creating) {
                TextField("Название", text: $newName)
                Button("Создать") { library.createPlaylist(newName) }
                Button("Отмена", role: .cancel) {}
            } message: { Text("В плейлист можно добавлять треки Яндекса и свои файлы через меню «…» у трека.") }
            .task(id: session.isLoggedIn) {
                guard session.isLoggedIn else { return }
                playlists = (try? await API.userPlaylists(uid: session.uid)) ?? []
                await library.refreshYandexPlaylists()
            }
            .onReceive(NotificationCenter.default.publisher(for: .yandexPlaylistsChanged)) { _ in
                Task { playlists = (try? await API.userPlaylists(uid: session.uid)) ?? playlists }
            }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.title2.bold()).foregroundStyle(.white).textCase(nil).padding(.top, 8)
    }

    private func row<D: View>(_ title: String, _ icon: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination() } label: {
            Label { Text(title).font(.title3) } icon: { Image(systemName: icon).foregroundStyle(Color.neon).shadow(color: Color.neon.opacity(0.6), radius: 6) }
                .padding(.vertical, 6)
        }
        .clearRow()
    }
}

extension View {
    /// Прозрачная строка списка, чтобы был виден фон с частицами.
    func clearRow() -> some View {
        self.listRowBackground(Color.clear).listRowSeparatorTint(.white.opacity(0.08))
    }
}

struct PlaylistsListView: View {
    @EnvironmentObject private var session: Session
    @State private var mine: [Playlist] = []
    @State private var liked: [Playlist] = []

    var body: some View {
        List {
            if !mine.isEmpty { Section("Мои") { ForEach(mine, id: \.playlistId) { row($0).clearRow() } } }
            if !liked.isEmpty { Section("Сохранённые") { ForEach(liked, id: \.playlistId) { row($0).clearRow() } } }
        }
        .listStyle(.plain)
        .yokayoBackground()
        .navigationTitle("Плейлисты")
        .task {
            async let m = try? API.userPlaylists(uid: session.uid)
            async let l = try? API.likedPlaylists()
            let (mm, ll) = await (m, l)
            mine = mm ?? []; liked = ll ?? []
        }
    }

    private func row(_ p: Playlist) -> some View {
        NavigationLink { PlaylistView(p) } label: {
            HStack(spacing: 14) {
                CoverView(url: p.coverURL, cornerRadius: 6, symbol: "music.note.list").frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text(p.title).lineLimit(1)
                    Text(p.owner?.name ?? p.owner?.login ?? "").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ArtistsListView: View {
    @State private var artists: [Artist] = []
    var body: some View {
        List(artists, id: \.id) { a in
            NavigationLink { ArtistView(artistId: a.id, name: a.artistName) } label: {
                HStack(spacing: 14) {
                    CoverView(url: a.coverURL(200), cornerRadius: 28, symbol: "music.microphone").frame(width: 56, height: 56)
                    Text(a.artistName)
                }
            }
            .clearRow()
        }
        .listStyle(.plain)
        .yokayoBackground()
        .navigationTitle("Артисты")
        .task { artists = (try? await API.likedArtists()) ?? [] }
    }
}

/// «Моя музыка»: свои mp3 и другие файлы.
struct MyMusicView: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var player: Player
    @State private var importing = false

    var body: some View {
        List {
            Section {
                Button { importing = true } label: {
                    Label("Добавить из «Файлов»", systemImage: "plus.circle.fill").font(.headline)
                }
                .clearRow()
                PlayShuffleButtons(songs: library.mySongs)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                    .clearRow()
            } footer: {
                Text("MP3, M4A, FLAC, WAV. Можно также закинуть файлы в папку Yokayo → MyMusic через «Файлы» или Finder.")
            }
            ForEach(Array(library.mySongs.enumerated()), id: \.element.id) { i, s in
                TrackRow(song: s)
                    .onTapGesture { player.play(library.mySongs, startAt: i) }
                    .clearRow()
            }
            .onDelete { idx in idx.map { library.mySongs[$0] }.forEach(library.remove) }
        }
        .listStyle(.plain)
        .yokayoBackground()
        .navigationTitle("Моя музыка")
        .overlay {
            if library.mySongs.isEmpty {
                ContentUnavailableView("Пока пусто", systemImage: "music.note", description: Text("Добавь свои треки — они будут играть вперемешку с Яндексом."))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
        .refreshable { await library.scanDocuments() }
    }
}
