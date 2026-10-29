import SwiftUI
import YMAPI

/// Поиск: жанры, пока поле пустое; результаты по категориям.
struct SearchView: View {
    @EnvironmentObject private var player: Player
    @State private var query = ""
    @State private var result: Search?
    @State private var scope = 0
    @State private var genres: [Genre] = []
    @State private var searching = false
    @AppStorage("searchHistory") private var historyRaw = ""
    private var history: [String] { historyRaw.split(separator: "\n").map(String.init) }

    private func remember(_ q: String) {
        var h = history.filter { $0.lowercased() != q.lowercased() }
        h.insert(q, at: 0)
        historyRaw = h.prefix(10).joined(separator: "\n")
    }

    private func isEmpty(_ r: Search) -> Bool {
        (r.tracks?.results ?? []).isEmpty && (r.albums?.results ?? []).isEmpty &&
        (r.artists?.results ?? []).isEmpty && (r.playlists?.results ?? []).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty { categories } else { results }
            }
            .yokayoBackground()
            .navigationTitle("Поиск")
            .searchable(text: $query, prompt: "Артисты, песни, альбомы")
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { result = nil; return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                searching = true
                let r = try? await API.search(q)
                if !Task.isCancelled {
                    result = r; searching = false
                    if let r, !isEmpty(r) { remember(q) }
                }
            }
            .task { if genres.isEmpty { genres = ((try? await API.genres()) ?? []).filter(\.showInMenu) } }
        }
    }

    private var categories: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !history.isEmpty {
                    HStack {
                        Text("Недавние").font(.title2.bold())
                        Spacer()
                        Button("Очистить") { historyRaw = "" }.font(.subheadline)
                    }
                    .padding(.horizontal, 20)
                    ForEach(history, id: \.self) { q in
                        Button { query = q } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                Text(q).foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 20).padding(.vertical, 6)
                        }
                    }
                    Divider().padding(.horizontal, 20).padding(.vertical, 6)
                }
                Text("Жанры").font(.title2.bold()).padding(.horizontal, 20)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                    ForEach(Array(genres.enumerated()), id: \.element.id) { i, g in
                        Button { query = g.title } label: {
                            ZStack(alignment: .bottomLeading) {
                                LinearGradient(colors: tileColors(i, g.color), startPoint: .topLeading, endPoint: .bottomTrailing)
                                Text(g.title).font(.headline).foregroundStyle(.white).padding(12)
                            }
                            .frame(height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScale())
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func tileColors(_ i: Int, _ hex: String?) -> [Color] {
        if let hex, let c = Color(hex: hex) { return [c, c.opacity(0.6)] }
        let hues = [0.58, 0.62, 0.7, 0.8, 0.95, 0.03, 0.1, 0.45, 0.52]
        let h = hues[i % hues.count]
        return [Color(hue: h, saturation: 0.75, brightness: 0.85), Color(hue: h + 0.04, saturation: 0.85, brightness: 0.55)]
    }

    @ViewBuilder private var results: some View {
        List {
            Picker("", selection: $scope) {
                Text("Всё").tag(0); Text("Треки").tag(1); Text("Альбомы").tag(2); Text("Артисты").tag(3); Text("Плейлисты").tag(4)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .clearRow()
            if searching && result == nil { ProgressView().frame(maxWidth: .infinity).clearRow() }
            if let r = result, isEmpty(r) {
                ContentUnavailableView.search(text: query).clearRow()
            }
            if let r = result {
                let songs = (r.tracks?.results ?? []).map(Song.init(track:))
                if scope == 0 || scope == 3 {
                    ForEach((r.artists?.results ?? []).prefix(scope == 0 ? 2 : 50), id: \.id) { a in
                        NavigationLink { ArtistView(artistId: a.id, name: a.artistName) } label: {
                            HStack(spacing: 12) {
                                CoverView(url: a.coverURL(200), cornerRadius: 24, symbol: "music.microphone").frame(width: 48, height: 48)
                                VStack(alignment: .leading) { Text(a.artistName); Text("Артист").font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                        .clearRow()
                    }
                }
                if scope == 0 || scope == 1 {
                    ForEach(Array(songs.prefix(scope == 0 ? 8 : 50).enumerated()), id: \.element.id) { i, s in
                        TrackRow(song: s).onTapGesture { player.play(songs, startAt: i) }.clearRow()
                    }
                }
                if scope == 0 || scope == 2 {
                    ForEach((r.albums?.results ?? []).prefix(scope == 0 ? 4 : 50), id: \.id) { a in
                        NavigationLink { AlbumView(albumId: a.id ?? 0) } label: {
                            HStack(spacing: 12) {
                                CoverView(url: a.coverURL(200), cornerRadius: 5).frame(width: 48, height: 48)
                                VStack(alignment: .leading) {
                                    Text(a.title ?? "").lineLimit(1)
                                    Text("Альбом · \(a.artistLine)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .clearRow()
                    }
                }
                if scope == 0 || scope == 4 {
                    ForEach((r.playlists?.results ?? []).prefix(scope == 0 ? 3 : 50), id: \.playlistId) { p in
                        NavigationLink { PlaylistView(p) } label: {
                            HStack(spacing: 12) {
                                CoverView(url: p.coverURL, cornerRadius: 5, symbol: "music.note.list").frame(width: 48, height: 48)
                                VStack(alignment: .leading) {
                                    Text(p.title).lineLimit(1)
                                    Text("Плейлист").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .clearRow()
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
