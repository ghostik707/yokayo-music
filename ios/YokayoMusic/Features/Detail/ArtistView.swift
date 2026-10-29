import SwiftUI
import YMAPI

/// Страница артиста: большое фото, популярные треки, альбомы, похожие.
struct ArtistView: View {
    let artistId: Int
    var name: String = ""
    @EnvironmentObject private var player: Player
    @State private var info: ArtistShortInfo?
    @State private var popular: [Song] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if info == nil { LoadState(loading: error == nil, error: error) { Task { await load() } } }
                if !popular.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Популярные треки") {
                            CollectionView(title: "Популярные треки", subtitle: displayName, coverURL: info?.artist?.coverURL(600)) { popular }
                        }
                        ForEach(Array(popular.prefix(5).enumerated()), id: \.element.id) { i, s in
                            TrackRow(song: s).padding(.horizontal, 20)
                                .onTapGesture { player.play(popular, startAt: i) }
                            Divider().padding(.leading, 80)
                        }
                    }
                }
                if let albums = info?.albums, !albums.isEmpty { albumRow("Альбомы", albums) }
                if let also = info?.alsoAlbums, !also.isEmpty { albumRow("Участвует", also) }
                if let similar = info?.similarArtists, !similar.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle("Похожие артисты")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(similar, id: \.id) { a in
                                    NavigationLink { ArtistView(artistId: a.id, name: a.artistName) } label: { ArtistBubble(artist: a) }
                                        .buttonStyle(.plain)
                                }
                            }.padding(.horizontal, 20)
                        }
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .yokayoBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task { if info == nil { await load() } }
    }

    private var displayName: String { info?.artist?.artistName ?? name }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            CoverView(url: info?.artist?.coverURL(1000), cornerRadius: 0, symbol: "music.microphone")
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom) {
                Text(displayName).font(.largeTitle.bold()).foregroundStyle(.white).lineLimit(2)
                Spacer()
                Button { player.play(popular) } label: {
                    Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 52, height: 52).background(Color.accentColor, in: Circle())
                }
                .disabled(popular.isEmpty)
            }
            .padding(20)
        }
    }

    private func albumRow(_ title: String, _ albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums, id: \.id) { a in
                        NavigationLink { AlbumView(albumId: a.id ?? 0) } label: {
                            MediaCard(url: a.coverURL(), title: a.title ?? "", subtitle: a.year.map(String.init))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20)
            }
        }
    }

    private func load() async {
        error = nil
        do {
            let i = try await API.artist(artistId)
            info = i
            popular = i.popularTracks.map(Song.init(track:))
        } catch { self.error = "Не удалось загрузить артиста." }
    }
}

struct ArtistBubble: View {
    let artist: Artist
    var body: some View {
        VStack(spacing: 8) {
            CoverView(url: artist.coverURL(300), cornerRadius: 70, symbol: "music.microphone")
                .frame(width: 120, height: 120)
            Text(artist.artistName).font(.subheadline).lineLimit(1).frame(width: 120)
        }
    }
}
