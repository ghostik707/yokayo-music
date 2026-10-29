import Foundation
import AVFoundation
import UIKit

/// «Моя музыка» (свои файлы) и офлайн-загрузки треков Яндекса внутри приложения.
@MainActor
final class LocalLibrary: ObservableObject {
    static let shared = LocalLibrary()

    @Published private(set) var mySongs: [Song] = []
    @Published private(set) var offlineSongs: [Song] = []
    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var playlists: [LocalPlaylist] = []
    /// Плейлисты аккаунта Яндекса — для меню «Добавить в плейлист».
    @Published private(set) var yandexPlaylists: [API.OwnPlaylist] = []

    nonisolated static var musicDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    nonisolated static var artworkDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    nonisolated static var offlineDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var dir = d; try? dir.setResourceValues(values)
        return d
    }
    nonisolated static func artworkURL(_ name: String) -> URL { artworkDir.appendingPathComponent(name) }
    nonisolated static func offlineURL(_ trackId: String) -> URL {
        offlineDir.appendingPathComponent(AudioFiles.safeName(trackId) + ".mp3")
    }

    private var myIndex: URL { Self.artworkDir.deletingLastPathComponent().appendingPathComponent("my-music.json") }
    private var offlineIndex: URL { Self.artworkDir.deletingLastPathComponent().appendingPathComponent("offline.json") }
    private var playlistsIndex: URL { Self.artworkDir.deletingLastPathComponent().appendingPathComponent("playlists.json") }

    init() {
        mySongs = (try? JSONDecoder().decode([Song].self, from: Data(contentsOf: myIndex))) ?? []
        offlineSongs = (try? JSONDecoder().decode([Song].self, from: Data(contentsOf: offlineIndex))) ?? []
        playlists = (try? JSONDecoder().decode([LocalPlaylist].self, from: Data(contentsOf: playlistsIndex))) ?? []
        Task { await scanDocuments(); await refreshYandexPlaylists() }
    }

    private func save() {
        try? JSONEncoder().encode(mySongs).write(to: myIndex)
        try? JSONEncoder().encode(offlineSongs).write(to: offlineIndex)
        try? JSONEncoder().encode(playlists).write(to: playlistsIndex)
    }

    // MARK: Свои плейлисты (треки Яндекса и свои файлы вместе)

    @discardableResult
    func createPlaylist(_ name: String) -> LocalPlaylist {
        let p = LocalPlaylist(id: UUID().uuidString, name: name.isEmpty ? "Новый плейлист" : name, songs: [], created: Date())
        playlists.insert(p, at: 0)
        save()
        return p
    }

    func add(_ songs: [Song], to playlistId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        let known = Set(playlists[i].songs.map(\.id))
        playlists[i].songs += songs.filter { !known.contains($0.id) }
        save()
    }

    func removeSong(_ song: Song, from playlistId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[i].songs.removeAll { $0.id == song.id }
        save()
    }

    func deletePlaylist(_ id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func renamePlaylist(_ id: String, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        playlists[i].name = name
        save()
    }

    func playlist(_ id: String) -> LocalPlaylist? { playlists.first { $0.id == id } }

    private static var uid: Int { Int(Keychain.get("uid") ?? "") ?? -1 }

    func refreshYandexPlaylists() async {
        let uid = Self.uid
        guard uid > 0 else { return }
        yandexPlaylists = await API.ownPlaylists(uid: uid)
    }

    /// Добавить в плейлист Яндекса; ответ — текст для всплывающей подсказки.
    func addToYandex(_ song: Song, playlist: API.OwnPlaylist) async -> String {
        guard !song.isLocal else { return "Свой файл можно добавить только в плейлист Yokayo" }
        do {
            try await API.add(song, toPlaylist: playlist.kind, uid: Self.uid)
            await refreshYandexPlaylists()
            NotificationCenter.default.post(name: .yandexPlaylistsChanged, object: nil)
            return "Добавлено в «\(playlist.title)»"
        } catch {
            return "Не получилось добавить в «\(playlist.title)»"
        }
    }

    // MARK: Свои файлы

    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf"]

    /// Импорт файлов, выбранных в «Файлах».
    func importFiles(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            let name = UUID().uuidString + "." + ext
            let dest = Self.musicDir.appendingPathComponent(name)
            do { try FileManager.default.copyItem(at: url, to: dest) } catch { continue }
            if let song = await Self.readSong(file: dest, fallbackTitle: url.deletingPathExtension().lastPathComponent) {
                mySongs.insert(song, at: 0)
            }
        }
        save()
    }

    /// Подхватывает файлы, закинутые в папку приложения через Finder или «Файлы».
    func scanDocuments() async {
        let known = Set(mySongs.compactMap { s -> String? in if case .local(let n) = s.source { return n }; return nil })
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.musicDir, includingPropertiesForKeys: nil)) ?? []
        var changed = false
        for f in files where Self.supportedExtensions.contains(f.pathExtension.lowercased()) && !known.contains(f.lastPathComponent) {
            if let song = await Self.readSong(file: f, fallbackTitle: f.deletingPathExtension().lastPathComponent) {
                mySongs.append(song); changed = true
            }
        }
        let existing = Set(files.map(\.lastPathComponent))
        let before = mySongs.count
        mySongs.removeAll { s in if case .local(let n) = s.source { return !existing.contains(n) }; return false }
        if changed || before != mySongs.count { save() }
    }

    func remove(_ song: Song) {
        if case .local(let name) = song.source {
            try? FileManager.default.removeItem(at: Self.musicDir.appendingPathComponent(name))
            if let art = song.localArtworkFile { try? FileManager.default.removeItem(at: Self.artworkURL(art)) }
            mySongs.removeAll { $0.id == song.id }
        } else if case .yandex(let id) = song.source {
            try? FileManager.default.removeItem(at: Self.offlineURL(id))
            offlineSongs.removeAll { $0.id == song.id }
        }
        save()
    }

    /// Своя обложка для своего трека (картинка; GIF/видео — анимированная).
    func setArtwork(for song: Song, imageData: Data) {
        guard let i = mySongs.firstIndex(where: { $0.id == song.id }) else { return }
        let name = UUID().uuidString + ".jpg"
        guard let img = UIImage(data: imageData), let jpg = img.jpegData(compressionQuality: 0.9) else { return }
        try? jpg.write(to: Self.artworkURL(name))
        mySongs[i].localArtworkFile = name
        save()
    }

    func setVideoCover(for song: Song, videoFile: URL) {
        guard let i = mySongs.firstIndex(where: { $0.id == song.id }) else { return }
        mySongs[i].videoCoverURL = videoFile
        save()
    }

    private static func readSong(file: URL, fallbackTitle: String) async -> Song? {
        let asset = AVURLAsset(url: file)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard duration > 0 else { return nil }
        let meta = (try? await asset.load(.commonMetadata)) ?? []
        func string(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: meta, withKey: key, keySpace: .common).first else { return nil }
            return try? await item.load(.stringValue)
        }
        var artName: String?
        if let item = AVMetadataItem.metadataItems(from: meta, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first,
           let data = try? await item.load(.dataValue), UIImage(data: data) != nil {
            artName = UUID().uuidString + ".jpg"
            try? data.write(to: artworkURL(artName!))
        }
        return Song(id: "local:" + file.lastPathComponent,
                    title: await string(.commonKeyTitle) ?? fallbackTitle,
                    artist: await string(.commonKeyArtist) ?? "Мой файл",
                    artistId: nil, albumId: nil,
                    albumTitle: await string(.commonKeyAlbumName),
                    coverURI: nil, localArtworkFile: artName,
                    durationMs: Int(duration * 1000), explicit: false, videoCoverURL: nil,
                    source: .local(fileName: file.lastPathComponent))
    }

    // MARK: Офлайн (только внутри приложения)

    func isOffline(_ song: Song) -> Bool { offlineSongs.contains { $0.id == song.id } }

    func download(_ songs: [Song]) {
        for song in songs where !song.isLocal && !isOffline(song) && !downloading.contains(song.id) {
            downloading.insert(song.id)
            Task {
                defer { downloading.remove(song.id) }
                guard case .yandex(let id) = song.source,
                      let src = try? await AudioFiles.shared.file(for: song, maxBitrate: AppSettings.shared.quality) else { return }
                let dest = Self.offlineURL(id)
                try? FileManager.default.removeItem(at: dest)
                guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return }
                offlineSongs.insert(song, at: 0)
                save()
            }
        }
    }

    static func offlineSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: offlineDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

extension Notification.Name { static let yandexPlaylistsChanged = Notification.Name("yandexPlaylistsChanged") }

struct LocalPlaylist: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var songs: [Song]
    var created: Date
    var coverURL: URL? { songs.first?.coverURL(400) }
}
