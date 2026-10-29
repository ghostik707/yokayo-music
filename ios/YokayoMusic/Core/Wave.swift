import Foundation
import YMAPI
import os

let waveLog = Logger(subsystem: "com.yokayo.music", category: "wave")

/// Прямые запросы к API Яндекс.Музыки (то, чего нет в YM-API).
enum YMRaw {
    static func request(_ method: String, _ path: String, body: [String: Any]? = nil, form: [String: String]? = nil) async throws -> Any {
        guard let token = Keychain.get("token") else { throw URLError(.userAuthenticationRequired) }
        var req = URLRequest(url: URL(string: YMConstants.apiBasePath + path)!)
        req.httpMethod = method
        req.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        req.setValue(YMConstants.xYmClient, forHTTPHeaderField: "X-Yandex-Music-Client")
        req.setValue("ru", forHTTPHeaderField: "Accept-Language")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let form {
            var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&").data(using: .utf8)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 300 {
            waveLog.error("\(method, privacy: .public) \(path, privacy: .public) -> \(code) \(String(data: data.prefix(300), encoding: .utf8) ?? "", privacy: .public)")
        }
        guard (resp as? HTTPURLResponse)?.statusCode ?? 500 < 300 else { throw URLError(.badServerResponse) }
        let json = try JSONSerialization.jsonObject(with: data)
        return (json as? [String: Any])?["result"] ?? json
    }

    static func tracks(fromSequence seq: Any?) -> [Track] {
        guard let items = seq as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let t = item["track"], let data = try? JSONSerialization.data(withJSONObject: t) else { return nil }
            return try? JSONDecoder().decode(Track.self, from: data)
        }
    }
}

/// «Моя волна»: новая сессия при каждом запуске + отчёты о прослушивании,
/// чтобы Яндекс подстраивал поток и не отдавал одну и ту же пачку.
@MainActor
final class Wave {
    static let shared = Wave()
    private let station = "user:onyourwave"
    private var sessionId: String?
    private var batchId: String?
    private var legacy = false
    private var seen: [String] = []

    private static var iso: String { ISO8601DateFormatter().string(from: Date()) }

    func start(trackSeed: String? = nil) async throws -> [Song] {
        sessionId = nil; batchId = nil; legacy = false; seen = []
        let seeds = trackSeed.map { ["track:" + $0] } ?? [station]
        do {
            let r = try await YMRaw.request("POST", "rotor/session/new",
                                            body: ["seeds": seeds, "includeTracksInResponse": true])
            guard let res = r as? [String: Any], let id = res["radioSessionId"] as? String else { throw URLError(.cannotParseResponse) }
            sessionId = id
            batchId = res["batchId"] as? String
            let songs = YMRaw.tracks(fromSequence: res["sequence"]).map(Song.init(track:))
            guard !songs.isEmpty else { throw URLError(.zeroByteResource) }
            await feedback(["type": "radioStarted", "timestamp": Self.iso, "from": "mobile-home-rup_main-user-onyourwave-default"])
            seen = songs.map(\.id)
            waveLog.notice("session ok \(id, privacy: .public) first=\(songs.first?.title ?? "-", privacy: .public) n=\(songs.count)")
            return songs
        } catch {
            waveLog.error("session failed: \(String(describing: error), privacy: .public)")
            // запасной путь: старая станция, но с отчётами
            legacy = true
            let c = YM.client
            _ = try? await ym { c.sendRadioStationStartListening(stationId: station, fromInfo: "mobile-radio-user-onyourwave", completion: $0) }
            let res = try await ym { c.getRadioStationTracksBatch(stationId: station, lastTrackId: nil, completion: $0) }
            batchId = res.batchId
            return res.sequence.compactMap(\.track).map(Song.init(track:)).shuffled()
        }
    }

    func more(after queue: [Song]) async throws -> [Song] {
        if !legacy, let sessionId {
            let ids = Array((seen + queue.map(\.id)).suffix(30))
            let r = try await YMRaw.request("POST", "rotor/session/\(sessionId)/tracks", body: ["queue": ids])
            let res = r as? [String: Any]
            if let b = res?["batchId"] as? String { batchId = b }
            let songs = YMRaw.tracks(fromSequence: res?["sequence"]).map(Song.init(track:))
            seen += songs.map(\.id)
            return songs
        }
        let c = YM.client
        let last: String? = { if case .yandex(let id)? = queue.last?.source { return id }; return nil }()
        let res = try await ym { c.getRadioStationTracksBatch(stationId: station, lastTrackId: last, completion: $0) }
        batchId = res.batchId
        return res.sequence.compactMap(\.track).map(Song.init(track:))
    }

    func started(_ song: Song) {
        guard case .yandex(let id) = song.source else { return }
        Task {
            if legacy {
                let c = YM.client
                _ = try? await ym { c.sendRadioTrackStartListening(stationId: station, tracksBatchId: batchId ?? "", trackId: id, completion: $0) }
            } else {
                await feedback(["type": "trackStarted", "timestamp": Self.iso, "trackId": id])
            }
        }
    }

    func ended(_ song: Song, played: Double, skipped: Bool) {
        guard case .yandex(let id) = song.source else { return }
        Task {
            if legacy {
                let c = YM.client
                if skipped { _ = try? await ym { c.sendRadioTrackSkip(stationId: station, trackId: id, playedSeconds: played, completion: $0) } }
                else { _ = try? await ym { c.sendRadioTrackFinished(stationId: station, tracksBatchId: batchId ?? "", trackId: id, playedDurationInS: played, completion: $0) } }
            } else {
                await feedback(["type": skipped ? "skip" : "trackFinished", "timestamp": Self.iso,
                                "trackId": id, "totalPlayedSeconds": played])
            }
        }
    }

    private func feedback(_ event: [String: Any]) async {
        guard let sessionId else { return }
        var body: [String: Any] = ["event": event]
        if let batchId { body["batchId"] = batchId }
        _ = try? await YMRaw.request("POST", "rotor/session/\(sessionId)/feedback", body: body)
    }
}
