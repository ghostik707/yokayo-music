import Foundation

/// То, что приложение показывает виджетам: текущий трек и состояние плеера.
/// Хранится в общей папке App Group (JSON + маленькая обложка).
struct WidgetState: Codable, Equatable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var djStatus: String?
    var hasArtwork: Bool
    var trackId: String
}

enum SharedStore {
    static let group = "group.com.yokayo.music"

    static var dir: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var stateURL: URL? { dir?.appendingPathComponent("widget-state.json") }
    static var artworkURL: URL? { dir?.appendingPathComponent("widget-artwork.jpg") }

    static func load() -> WidgetState? {
        guard let url = stateURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetState.self, from: data)
    }

    static func save(_ state: WidgetState) {
        guard let url = stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func saveArtwork(_ jpeg: Data) {
        guard let url = artworkURL else { return }
        try? jpeg.write(to: url, options: .atomic)
    }

    static func artworkData() -> Data? {
        guard let url = artworkURL else { return nil }
        return try? Data(contentsOf: url)
    }
}
