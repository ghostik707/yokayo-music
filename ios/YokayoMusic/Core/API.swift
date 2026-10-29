import Foundation
import YMAPI

/// Высокоуровневые запросы к Яндекс.Музыке.
enum API {
    private static var c: YMClient { YM.client }

    static func feed() async throws -> Feed { try await ym { c.getFeed(completion: $0) } }

    /// Чарт: прямой запрос, разбор трекoв вручную (модель библиотеки устарела).
    static func chart() async throws -> [Song] {
        let r = try await YMRaw.request("GET", "landing3/chart/russia")
        let chart = (r as? [String: Any])?["chart"] as? [String: Any]
        return YMRaw.tracks(fromSequence: chart?["tracks"]).map(Song.init(track:))
    }

    static func newReleases() async throws -> [Album] {
        let list = try await ym { c.getNewAlbums(completion: $0) }
        let ids = (list.newReleases ?? []).prefix(20).map(String.init)
        guard !ids.isEmpty else { return [] }
        return try await ym { c.getAlbums(albumIds: Array(ids), completion: $0) }
    }

    static func newPlaylists() async throws -> [Playlist] {
        let list = try await ym { c.getNewPlaylists(completion: $0) }
        let ids = (list.newPlaylists ?? []).prefix(16)
        var result: [Playlist] = []
        for pid in ids {
            if let p = try? await ym({ c.getPlaylists(userId: String(pid.uid), playlistsId: [String(pid.kind)], completion: $0) }).first {
                result.append(p)
            }
        }
        return result
    }

    static func playlist(uid: Int, kind: Int) async throws -> Playlist {
        let list = try await ym { c.getPlaylists(userId: String(uid), playlistsId: [String(kind)], completion: $0) }
        guard let p = list.first else { throw URLError(.fileDoesNotExist) }
        return p
    }

    /// Треки плейлиста: часть уже приходит целиком, остальное догружаем.
    static func songs(of playlist: Playlist) async throws -> [Song] {
        let shorts = playlist.tracks ?? []
        var full: [String: Track] = [:]
        for s in shorts { if let t = s.track { full[s.trackId] = t } }
        let missing = shorts.map(\.trackId).filter { full[$0] == nil }
        for chunk in stride(from: 0, to: missing.count, by: 200).map({ Array(missing[$0..<min($0 + 200, missing.count)]) }) {
            let tracks = try await ym { c.getTracks(trackIds: chunk, positions: false, completion: $0) }
            for t in tracks { full[t.trackId] = t; full[t.id] = t }
        }
        return shorts.compactMap { s in
            (full[s.trackId] ?? full[String(s.id)]).map(Song.init(track:))
        }
    }

    /// Свои плейлисты Яндекса (куда можно добавлять треки).
    struct OwnPlaylist: Identifiable, Hashable { let kind: Int; let title: String; let count: Int; var id: Int { kind } }

    static func ownPlaylists(uid: Int) async -> [OwnPlaylist] {
        guard let list = try? await YMRaw.request("GET", "users/\(uid)/playlists/list") as? [[String: Any]] else { return [] }
        return list.compactMap { p in
            guard let kind = p["kind"] as? Int, let title = p["title"] as? String else { return nil }
            return OwnPlaylist(kind: kind, title: title, count: p["trackCount"] as? Int ?? 0)
        }
    }

    /// Добавить трек в начало своего плейлиста Яндекса.
    static func add(_ song: Song, toPlaylist kind: Int, uid: Int) async throws {
        guard case .yandex = song.source else { throw URLError(.unsupportedURL) }
        let base = song.id.split(separator: ":").first.map(String.init) ?? song.id
        let info = try await YMRaw.request("GET", "users/\(uid)/playlists/\(kind)") as? [String: Any]
        let revision = info?["revision"] as? Int ?? 1
        var track: [String: Any] = ["id": base]
        if let albumId = song.albumId { track["albumId"] = String(albumId) }
        let diff: [[String: Any]] = [["op": "insert", "at": 0, "tracks": [track]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: diff), encoding: .utf8) ?? "[]"
        _ = try await YMRaw.request("POST", "users/\(uid)/playlists/\(kind)/change-relative",
                                    form: ["diff": json, "revision": String(revision)])
    }

    static func userPlaylists(uid: Int) async throws -> [Playlist] {
        try await ym { c.getUserPlaylists(userId: String(uid), completion: $0) }
    }

    static func likedSongs() async throws -> [Song] {
        let lib = try await ym { c.getLikedTracks(modifiedRevision: nil, completion: $0) }
        let ids = (lib.tracks ?? []).compactMap { like -> String? in
            guard let id = like.id else { return nil }
            if let a = like.albumId { return id + ":" + a }
            return id
        }
        var songs: [Song] = []
        for start in stride(from: 0, to: ids.count, by: 200) {
            let chunk = Array(ids[start..<min(start + 200, ids.count)])
            let tracks = try await ym { c.getTracks(trackIds: chunk, positions: false, completion: $0) }
            songs += tracks.map(Song.init(track:))
        }
        return songs
    }

    static func likedArtists() async throws -> [Artist] {
        let likes = try await ym { c.getLikedArtists(likeTs: false, completion: $0) }
        return likes.compactMap(\.artist)
    }

    static func likedPlaylists() async throws -> [Playlist] {
        let likes = try await ym { c.getLikedPlaylists(completion: $0) }
        return likes.compactMap(\.playlist)
    }

    static func album(_ id: Int) async throws -> Album {
        try await ym { c.getAlbumWithTracksData(albumId: String(id), completion: $0) }
    }

    static func artist(_ id: Int) async throws -> ArtistShortInfo {
        try await ym { c.getArtistShortInfo(artistId: String(id), completion: $0) }
    }

    static func search(_ text: String) async throws -> Search {
        try await ym { c.search(text: text, noCorrect: false, type: .all, page: 0, includeBestPlaylists: true, completion: $0) }
    }

    static func searchTracks(_ text: String) async throws -> [Track] {
        let s = try await ym { c.search(text: text, noCorrect: false, type: .track, page: 0, includeBestPlaylists: false, completion: $0) }
        return s.tracks?.results ?? []
    }

    static func genres() async throws -> [Genre] { try await ym { c.getGenres(completion: $0) } }

    /// «Моя волна» — бесконечная станция. Возвращает пачку треков.
    static func waveBatch(after lastTrackId: String?) async throws -> [Song] {
        let res = try await ym { c.getRadioStationTracksBatch(stationId: "user:onyourwave", lastTrackId: lastTrackId, completion: $0) }
        return res.sequence.compactMap(\.track).map(Song.init(track:))
    }

    static func setLike(_ song: Song, liked: Bool) async {
        guard case .yandex(let id) = song.source else { return }
        if liked { _ = try? await ym { c.likeTracks(trackIds: [id], completion: $0) } }
        else { _ = try? await ym { c.removeLikeTracks(trackIds: [id], completion: $0) } }
    }

    static func likedIds() async -> Set<String> {
        guard let lib = try? await ym({ c.getLikedTracks(modifiedRevision: nil, completion: $0) }) else { return [] }
        return Set((lib.tracks ?? []).compactMap { like in
            guard let id = like.id else { return nil }
            return like.albumId.map { id + ":" + $0 } ?? id
        })
    }

    /// Прямая ссылка на аудиопоток: mp3 с битрейтом не выше выбранного.
    static func streamURL(trackId: String, maxBitrate: Int) async throws -> URL {
        let track = try await TrackStore.shared.track(trackId)
        let infos = try await ym { track.getDownloadInfo(completion: $0) }
        let mp3 = infos.filter { $0.codec == "mp3" && !$0.preview }.sorted { $0.bitrateInKbps > $1.bitrateInKbps }
        let pick = mp3.first { $0.bitrateInKbps <= maxBitrate } ?? mp3.last ?? infos.first
        guard let pick else { throw URLError(.resourceUnavailable) }
        let link = try await ym { pick.getDirectLink(completion: $0) }
        guard let url = URL(string: link) else { throw URLError(.badURL) }
        return url
    }
}
