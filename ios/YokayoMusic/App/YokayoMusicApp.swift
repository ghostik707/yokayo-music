import SwiftUI

@main
struct YokayoMusicApp: App {
    @StateObject private var session = Session()
    @StateObject private var player = Player.shared
    @StateObject private var library = LocalLibrary.shared
    @StateObject private var settings = AppSettings.shared

    init() {
        _ = NetworkStatus.shared     // начать следить за сетью заранее
        // Команды из виджетов, Пункта управления и Siri.
        PlaybackBridge.handler = { action in
            let p = Player.shared
            switch action {
            case .toggle: p.togglePlay()
            case .pause: p.pause()
            case .next: p.next()
            case .previous: p.previous()
            case .wave: p.playWave()
            case .djToggle:
                AppSettings.shared.djEnabled.toggle()
                p.toast = AppSettings.shared.djEnabled ? "DJ-режим включён" : "DJ-режим выключен"
                if AppSettings.shared.djEnabled { p.prepareNext() }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(settings)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: Player

    var body: some View {
        ZStack {
            if settings.onboarded {
                MainTabView().transition(.opacity)
            } else {
                OnboardingView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: settings.onboarded)
        .task(id: session.isLoggedIn) {
            if session.isLoggedIn { await player.loadLikes() }
        }
        .overlay(alignment: .top) { ToastView() }
        .preferredColorScheme(.dark)
        .tint(.neon)
    }
}

/// Короткое всплывающее сообщение сверху.
struct ToastView: View {
    @EnvironmentObject private var player: Player
    var body: some View {
        if let text = player.toast {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { player.toast = nil }
                }
        }
    }
}
