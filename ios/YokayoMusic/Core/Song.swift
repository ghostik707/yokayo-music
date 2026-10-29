import Foundation
import YMAPI

/// Единая модель трека для плеера: трек Яндекса или свой файл.
struct Song: Identifiable, Hashable, Codable {
    enum Source: Hashable, Codable {
        case yandex(trackId: String)      // "id:albumId"
        case local(fileName: String)       // файл в Documents/MyMusic
    }

    let id: String
    var title: String
    var artist: String
    var artistId: Int?
    var albumId: Int?
    var albumTitle: String?
    var coverURI: String?
    var localArtworkFile: String?
    var durationMs: Int
    var explicit: Bool
    var videoCoverURL: URL?
    var source: Source
    var loudness: Float? = nil      // интегральная громкость, LUFS (из Яндекса)
    var truePeak: Float? = nil

    /// Поправка до −14 LUFS, без клиппинга.
    var normalizationGain: Float {
        guard let loudness else { return 0 }
        var g = -14 - loudness
        if let truePeak { g = min(g, -1 - truePeak) }
        return max(-12, min(6, g))
    }

    var isLocal: Bool { if case .local = source { return true } else { return false } }

    var shareURL: URL? {
        guard case .yandex = source else { return nil }
        let base = id.split(separator: ":").first.map(String.init) ?? id
        if let albumId { return URL(string: "https://music.yandex.ru/album/\(albumId)/track/\(base)") }
        return URL(string: "https://music.yandex.ru/track/\(base)")
    }

    func coverURL(_ size: Int) -> URL? {
        if let localArtworkFile { return LocalLibrary.artworkURL(localArtworkFile) }
        return YM.imageURL(coverURI, size: size)
    }
}

extension Song {
    init(track: Track) {
        let trackId = track.trackId
        id = trackId
        let version = (track.version ?? "").trimmingCharacters(in: .whitespaces)
        let base = track.title ?? "Без названия"
        title = version.isEmpty ? base : "\(base) (\(version))"
        artist = track.artistsName.joined(separator: ", ")
        artistId = track.artists.first?.id
        albumId = track.albums.first?.id
        albumTitle = track.albums.first?.title
        coverURI = track.coverUri ?? track.albums.first?.coverUri
        localArtworkFile = nil
        durationMs = track.durationMs
        explicit = track.explicit == true || track.contentWarning == "explicit"
        if let v = track.backgroundVideoUri, let url = URL(string: v) { videoCoverURL = url } else { videoCoverURL = nil }
        source = .yandex(trackId: trackId)
        loudness = track.r128?.i
        truePeak = track.r128?.tp
        TrackStore.shared.remember(track)
    }
}

/// Хранит объекты Track из библиотеки — они нужны, чтобы получить ссылку на поток.
final class TrackStore: @unchecked Sendable {
    static let shared = TrackStore()
    private var tracks: [String: Track] = [:]
    private let lock = NSLock()

    func remember(_ track: Track) {
        lock.withLock { tracks[track.trackId] = track }
    }

    func track(_ id: String) async throws -> Track {
        let cached = lock.withLock { tracks[id] }
        if let cached { return cached }
        let client = YM.client
        let list = try await ym { client.getTracks(trackIds: [id], positions: false, completion: $0) }
        guard let t = list.first else { throw URLError(.fileDoesNotExist) }
        remember(t)
        return t
    }
}
