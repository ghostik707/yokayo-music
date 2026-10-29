import SwiftUI
import YMAPI

/// «Обзор»: новые плейлисты и релизы, жанры.
struct BrowseView: View {
    @EnvironmentObject private var session: Session
    @State private var playlists: [Playlist] = []
    @State private var releases: [Album] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if !session.isLoggedIn { LoginPromptCard().padding(.horizontal, 20) }
                    if loading { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    if let hero = playlists.first {
                        NavigationLink { PlaylistView(hero) } label: { HeroCard(playlist: hero) }
                            .buttonStyle(PressScale()).padding(.horizontal, 20)
                    }
                    if playlists.count > 1 {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle("Новые плейлисты")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(playlists.dropFirst(), id: \.playlistId) { p in
                                        NavigationLink { PlaylistView(p) } label: {
                                            MediaCard(url: p.coverURL, title: p.title, subtitle: p.owner?.name)
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.horizontal, 20)
                            }
                        }
                    }
                    if !releases.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle("Свежие альбомы")
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 18) {
                                ForEach(releases, id: \.id) { a in
                                    NavigationLink { AlbumView(albumId: a.id ?? 0) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            CoverView(url: a.coverURL(), cornerRadius: 10)
                                            Text(a.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                                            Text(a.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .yokayoBackground()
            .navigationTitle("Обзор")
            .task(id: session.isLoggedIn) { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard session.isLoggedIn else { return }
        loading = playlists.isEmpty
        async let p = try? API.newPlaylists()
        async let r = try? API.newReleases()
        let (pp, rr) = await (p, r)
        playlists = pp ?? []
        releases = Array((rr ?? []).dropFirst(10))
        loading = false
    }
}

/// Большая карточка-баннер в «Обзоре».
struct HeroCard: View {
    let playlist: Playlist
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("НОВЫЙ ПЛЕЙЛИСТ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(playlist.title).font(.title2).lineLimit(1)
            CoverView(url: playlist.coverURL, cornerRadius: 14)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
