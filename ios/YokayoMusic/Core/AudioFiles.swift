import Foundation

/// Даёт локальный файл для воспроизведения: свой mp3, загрузку или кэш потока.
actor AudioFiles {
    static let shared = AudioFiles()

    private var inFlight: [String: Task<URL, Error>] = [:]
    private let cacheLimit: Int64 = 600 * 1024 * 1024

    static var streamDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Stream", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func safeName(_ id: String) -> String {
        id.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
    }

    func file(for song: Song, maxBitrate: Int) async throws -> URL {
        switch song.source {
        case .local(let name):
            return LocalLibrary.musicDir.appendingPathComponent(name)
        case .yandex(let trackId):
            let offline = LocalLibrary.offlineURL(trackId)
            if FileManager.default.fileExists(atPath: offline.path) { return offline }
            let cached = Self.streamDir.appendingPathComponent(Self.safeName(trackId) + ".mp3")
            if FileManager.default.fileExists(atPath: cached.path) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
                return cached
            }
            if let task = inFlight[trackId] { return try await task.value }
            let task = Task<URL, Error> {
                let remote = try await API.streamURL(trackId: trackId, maxBitrate: maxBitrate)
                let (tmp, response) = try await URLSession.shared.download(from: remote)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw URLError(.badServerResponse) }
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.moveItem(at: tmp, to: cached)
                return cached
            }
            inFlight[trackId] = task
            defer { inFlight[trackId] = nil }
            let url = try await task.value
            trimCache()
            return url
        }
    }

    /// Удаляет самые старые файлы кэша, если он больше лимита.
    private func trimCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.streamDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var items = files.compactMap { url -> (URL, Int64, Date)? in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
        }
        var total = items.reduce(0) { $0 + $1.1 }
        guard total > cacheLimit else { return }
        items.sort { $0.2 < $1.2 }
        for item in items where total > cacheLimit {
            try? fm.removeItem(at: item.0)
            total -= item.1
        }
    }

    static func cacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: streamDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: streamDir)
    }
}
