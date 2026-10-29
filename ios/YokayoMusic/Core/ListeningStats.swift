import Foundation

/// Сколько и что ты слушал. Хранится только на телефоне.
@MainActor
final class ListeningStats: ObservableObject {
    static let shared = ListeningStats()

    struct Meta: Codable { var title: String; var artist: String; var cover: String? }
    /// день (yyyy-MM-dd) → id трека → секунды
    @Published private(set) var days: [String: [String: Double]] = [:]
    private(set) var meta: [String: Meta] = [:]
    private var pending = 0.0

    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("stats.json")
    }
    private struct Store: Codable { var days: [String: [String: Double]]; var meta: [String: Meta] }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func key(_ d: Date) -> String { dayFormat.string(from: d) }

    init() {
        if let s = try? JSONDecoder().decode(Store.self, from: Data(contentsOf: url)) { days = s.days; meta = s.meta }
    }

    /// Вызывается из таймера плеера.
    func add(_ song: Song, seconds: Double) {
        let k = Self.key(Date())
        days[k, default: [:]][song.id, default: 0] += seconds
        if meta[song.id] == nil { meta[song.id] = Meta(title: song.title, artist: song.artist, cover: song.coverURL(200)?.absoluteString) }
        pending += seconds
        if pending > 15 { pending = 0; save() }
    }

    func save() {
        try? JSONEncoder().encode(Store(days: days, meta: meta)).write(to: url, options: .atomic)
    }

    // MARK: Выборки

    func totals(lastDays: Int?) -> [String: Double] {
        let keys: Set<String>? = lastDays.map { n in Set((0..<n).map { Self.key(Date().addingTimeInterval(-Double($0) * 86400)) }) }
        var out: [String: Double] = [:]
        for (day, tracks) in days where keys?.contains(day) ?? true {
            for (id, s) in tracks { out[id, default: 0] += s }
        }
        return out
    }

    func minutesPerDay(_ n: Int) -> [(date: Date, minutes: Double)] {
        (0..<n).reversed().map { i in
            let d = Date().addingTimeInterval(-Double(i) * 86400)
            return (d, (days[Self.key(d)] ?? [:]).values.reduce(0, +) / 60)
        }
    }

    var streak: Int {
        var n = 0
        while (days[Self.key(Date().addingTimeInterval(-Double(n) * 86400))]?.values.reduce(0, +) ?? 0) > 60 { n += 1 }
        return n
    }
}
