import SwiftUI
import WebKit

/// Красивая шторка входа: страница Яндекс ID внутри приложения.
struct LoginSheet: View {
    var onSuccess: () -> Void
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .web
    @State private var reload = 0
    @State private var pageLoading = true

    enum Phase: Equatable { case web, exchanging, done, failed(String) }

    var body: some View {
        ZStack {
            YokayoBackground()
            VStack(spacing: 0) {
                header
                ZStack {
                    YandexLoginWebView(reload: reload, loading: $pageLoading) { trackId, cookie in
                        Task { await exchange(trackId: trackId, cookie: cookie) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .opacity(phase == .web ? 1 : 0.15)
                    .blur(radius: phase == .web ? 0 : 6)
                    if pageLoading && phase == .web { ProgressView().tint(.white) }
                    overlay
                }
                .padding(.horizontal, 12)
                Text("Пароль вводится только на странице Яндекса. Yokayo хранит лишь токен доступа — в связке ключей iPhone.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
                    .padding(.horizontal, 30).padding(.vertical, 12)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 34, height: 34).background(.white.opacity(0.12), in: Circle())
                }
                Spacer()
                Button { reload += 1; phase = .web } label: {
                    Image(systemName: "arrow.clockwise").font(.headline).frame(width: 34, height: 34).background(.white.opacity(0.12), in: Circle())
                }
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .padding(.horizontal, 18)
            GlowingStar(size: 54)
            Text("Вход в Yokayo").font(.title2.bold()).foregroundStyle(.white)
            Text("Войди в свой аккаунт Яндекса — подтянем подписку, плейлисты и «Мою волну».")
                .font(.subheadline).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .padding(.top, 14).padding(.bottom, 14)
    }

    @ViewBuilder private var overlay: some View {
        switch phase {
        case .web: EmptyView()
        case .exchanging:
            VStack(spacing: 16) {
                GlowingStar(size: 90)
                Text("Подключаем аккаунт…").font(.headline).foregroundStyle(.white)
            }
        case .done:
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(Color.neon)
                    .symbolEffect(.bounce, value: phase)
                Text("Готово, \(session.displayName.isEmpty ? "добро пожаловать" : session.displayName)!").font(.headline).foregroundStyle(.white)
            }
            .transition(.scale.combined(with: .opacity))
        case .failed(let msg):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 50)).foregroundStyle(.yellow)
                Text(msg).foregroundStyle(.white).multilineTextAlignment(.center).padding(.horizontal)
                Button("Попробовать ещё раз") { reload += 1; phase = .web }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func exchange(trackId: String, cookie: String) async {
        withAnimation { phase = .exchanging }
        do {
            try await session.finishLogin(trackId: trackId, cookie: cookie)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring) { phase = .done }
            try? await Task.sleep(for: .seconds(1.3))
            dismiss()
            onSuccess()
        } catch {
            withAnimation { phase = .failed(error.localizedDescription) }
        }
    }
}

/// WKWebView со страницей паспорта Яндекса. Ловит trackId и cookie после входа.
struct YandexLoginWebView: UIViewRepresentable {
    var reload: Int
    @Binding var loading: Bool
    var onFinish: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        context.coordinator.start(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastReload != reload {
            context.coordinator.lastReload = reload
            context.coordinator.start(web)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: YandexLoginWebView
        var lastReload = 0
        private var finished = false
        init(_ p: YandexLoginWebView) { parent = p; lastReload = p.reload }

        func start(_ web: WKWebView) {
            finished = false
            guard let req = YM.client.generateInitAuthSessionRequest().1 else { return }
            web.load(req)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.loading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.loading = false }
            if let url = webView.url { check(url, webView) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let url = navigationResponse.response.url { check(url, webView) }
            decisionHandler(.allow)
        }

        private func check(_ url: URL, _ web: WKWebView) {
            guard !finished, let trackId = Self.trackId(url) else { return }
            finished = true
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let cookie = cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ")
                DispatchQueue.main.async { self.parent.onFinish(trackId, cookie) }
            }
        }

        static func trackId(_ url: URL) -> String? {
            let s = url.absoluteString
            guard s.contains("passport.yandex.ru/am/finish"), s.contains("status=ok") else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?
                .first { ($0.name == "track_id" || $0.name == "trackId") && !($0.value ?? "").isEmpty }?.value
        }
    }
}
