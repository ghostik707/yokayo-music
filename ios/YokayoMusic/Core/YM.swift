import Foundation
import UIKit
import YMAPI

/// Превращает колбэк библиотеки YM-API в async/await.
/// Защищён от повторного вызова колбэка (в библиотеке такое бывает).
func ym<T>(_ body: (@escaping (Result<T, YMError>) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        let once = Once()
        body { result in
            guard once.claim() else { return }
            cont.resume(with: result.mapError { $0 as Error })
        }
    }
}

private final class Once: @unchecked Sendable {
    private var used = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

enum YM {
    static var client: YMClient { YMClient.shared }

    static func makeDevice() -> YMDevice {
        let defaults = UserDefaults.standard
        func stableId(_ key: String) -> String {
            if let v = defaults.string(forKey: key) { return v }
            let v = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            defaults.set(v, forKey: key)
            return v
        }
        return YMDevice(os: "iOS", osVer: UIDevice.current.systemVersion, manufacturer: "Apple",
                        name: "iPhone", platform: "iPhone", model: "iPhone",
                        clid: "app-store", deviceId: stableId("ym.deviceId"), uuid: stableId("ym.uuid"))
    }

    /// Ссылка на картинку Яндекса: шаблон `avatars.yandex.net/...%%` → нужный размер.
    static func imageURL(_ uri: String?, size: Int) -> URL? {
        guard let uri, !uri.isEmpty else { return nil }
        let s = [50, 100, 200, 300, 400, 600, 800, 1000].first { $0 >= size } ?? 1000
        let path = uri.replacingOccurrences(of: "%%", with: "\(s)x\(s)")
        return URL(string: path.hasPrefix("http") ? path : "https://" + path)
    }
}
