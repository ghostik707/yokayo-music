import SwiftUI
import YMAPI

/// Поиск версии трека без цензуры: сначала в каталоге Яндекса, затем ссылки на другие сервисы.
struct UncensoredSheet: View {
    let song: Song
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var versions: [Song] = []
    @State private var links: [(String, URL)] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    else if versions.isEmpty { Text("В каталоге Яндекса других версий не нашлось.").foregroundStyle(.secondary) }
                    ForEach(versions) { v in
                        Button {
                            player.replaceCurrent(with: v)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                CoverView(url: v.coverURL(100), cornerRadius: 5).frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) { Text(v.title).lineLimit(1); if v.explicit { ExplicitBadge() } }
                                    Text("\(v.artist) · \(v.albumTitle ?? "")").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(formatTime(Double(v.durationMs) / 1000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("Другие версии в Яндексе") } footer: {
                    Text("Сначала — версии с пометкой «E». Нажми, чтобы заменить текущий трек.")
                }
                if !links.isEmpty {
                    Section {
                        ForEach(links, id: \.0) { name, url in
                            Button { openURL(url) } label: { Label(name, systemImage: "arrow.up.right.square") }
                        }
                    } header: { Text("Открыть в другом сервисе") } footer: {
                        Text("Если в Яндексе трек отредактирован, оригинал можно послушать в сервисе, где он есть.")
                    }
                }
            }
            .yokayoBackground()
            .navigationTitle("Версия без цензуры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        let base = song.title.replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression)
        let tracks = (try? await API.searchTracks("\(song.artist) \(base)")) ?? []
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression) }
        versions = tracks.map(Song.init(track:))
            .filter { $0.id != song.id && norm($0.title) == norm(song.title) }
            .sorted { ($0.explicit ? 0 : 1) < ($1.explicit ? 0 : 1) }
        loading = false
        links = await OtherServices.links(for: song)
    }
}

/// Ссылки на тот же трек в других сервисах через открытый API song.link.
enum OtherServices {
    static func links(for song: Song) async -> [(String, URL)] {
        guard let share = song.shareURL,
              var comps = URLComponents(string: "https://api.song.link/v1-alpha.1/links") else { return [] }
        comps.queryItems = [URLQueryItem(name: "url", value: share.absoluteString), URLQueryItem(name: "userCountry", value: "US")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platforms = json["linksByPlatform"] as? [String: [String: Any]] else { return [] }
        let names = [("appleMusic", "Apple Music"), ("spotify", "Spotify"), ("youtubeMusic", "YouTube Music"), ("deezer", "Deezer")]
        return names.compactMap { key, title in
            guard let s = platforms[key]?["url"] as? String, let u = URL(string: s) else { return nil }
            return (title, u)
        }
    }
}
