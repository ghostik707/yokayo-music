import Foundation
import YMAPI

/// Сессия пользователя: токены, клиент API, данные аккаунта.
@MainActor
final class Session: ObservableObject {
    @Published private(set) var isLoggedIn = false
    @Published private(set) var displayName: String = ""
    @Published private(set) var login: String = ""
    @Published private(set) var hasPlus = false
    @Published private(set) var avatarURL: URL?

    var uid: Int { YM.client.accountUid }

    init() {
        let token = Keychain.get("token") ?? ""
        let xToken = Keychain.get("xToken") ?? ""
        let uid = Int(Keychain.get("uid") ?? "") ?? -1
        if !token.isEmpty, uid > 0 {
            _ = YMClient.initialize(device: YM.makeDevice(), lang: .ru, uid: uid, token: token, xToken: xToken)
            isLoggedIn = true
            Task { await refreshAccount() }
        } else {
            _ = YMClient.initialize(device: YM.makeDevice(), lang: .ru)
        }
    }

    /// Шаг 3 входа: из trackId и cookie паспорта получаем X-Token, затем токен Музыки.
    func finishLogin(trackId: String, cookie: String) async throws {
        let client = YM.client
        let x = try await ym { client.generateXTokenFromChallengeTrackId(trackId: trackId, yaClientCookie: cookie, completion: $0) }
        guard let xToken = x[.access_token], !xToken.isEmpty else { throw LoginError.noToken }
        let t = try await ym { client.generateYMTokenFromXToken(xToken: xToken, completion: $0) }
        guard let token = t[.access_token], !token.isEmpty, let uid = Int(t[.uid] ?? "") else { throw LoginError.noToken }
        Keychain.set(token, for: "token")
        Keychain.set(xToken, for: "xToken")
        Keychain.set(String(uid), for: "uid")
        _ = YMClient.initialize(device: YM.makeDevice(), lang: .ru, uid: uid, token: token, xToken: xToken)
        isLoggedIn = true
        await refreshAccount()
    }

    func refreshAccount() async {
        // прямой запрос: модель библиотеки не разбирает новый ответ Яндекса
        if let r = try? await YMRaw.request("GET", "account/status") as? [String: Any] {
            let acc = r["account"] as? [String: Any] ?? [:]
            displayName = (acc["displayName"] as? String) ?? (acc["fullName"] as? String) ?? (acc["login"] as? String) ?? ""
            login = acc["login"] as? String ?? ""
            let plus = (r["plus"] as? [String: Any])?["hasPlus"] as? Bool
            let sub = r["subscription"] as? [String: Any]
            let renewable = !((sub?["autoRenewable"] as? [Any]) ?? []).isEmpty || !((sub?["familyAutoRenewable"] as? [Any]) ?? []).isEmpty
            hasPlus = plus ?? renewable
            waveLog.notice("account ok name=\(self.displayName, privacy: .public) plus=\(self.hasPlus)")
        } else {
            waveLog.error("account/status failed")
        }
        avatarURL = await Self.fetchAvatar()
        waveLog.notice("avatar \(self.avatarURL?.absoluteString ?? "nil", privacy: .public)")
    }

    /// Аватарка Яндекс ID: сначала по токену Музыки, затем через паспорт по X-Token.
    private static func fetchAvatar() async -> URL? {
        if let token = Keychain.get("token") {
            var req = URLRequest(url: URL(string: "https://login.yandex.ru/info?format=json")!)
            req.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = json["default_avatar_id"] as? String, json["is_avatar_empty"] as? Bool != true {
                return URL(string: "https://avatars.yandex.net/get-yapic/\(id)/islands-200")
            }
        }
        if let x = Keychain.get("xToken") {
            var req = URLRequest(url: URL(string: "https://mobileproxy.passport.yandex.net/1/bundle/account/short_info/?avatar_size=islands-200")!)
            req.setValue("OAuth " + x, forHTTPHeaderField: "Ya-Consumer-Authorization")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let s = json["avatar_url"] as? String, let u = URL(string: s) {
                return u
            }
        }
        return nil
    }

    func logout() {
        for key in ["token", "xToken", "uid"] { Keychain.set(nil, for: key) }
        _ = YMClient.initialize(device: YM.makeDevice(), lang: .ru)
        displayName = ""; login = ""; hasPlus = false; avatarURL = nil
        isLoggedIn = false
    }

    enum LoginError: LocalizedError {
        case noToken
        var errorDescription: String? { "Яндекс не выдал токен. Попробуйте войти ещё раз." }
    }
}
