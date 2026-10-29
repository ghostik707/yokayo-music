import AppIntents

/// Фразы для Siri и «Команд».
struct YokayoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayWaveIntent(),
                    phrases: ["Включи мою волну в \(.applicationName)", "Моя волна в \(.applicationName)"],
                    shortTitle: "Моя волна", systemImageName: "sparkle")
        AppShortcut(intent: TogglePlaybackIntent(),
                    phrases: ["Пауза в \(.applicationName)", "Продолжи \(.applicationName)"],
                    shortTitle: "Играть/пауза", systemImageName: "playpause.fill")
        AppShortcut(intent: NextTrackIntent(),
                    phrases: ["Следующий трек в \(.applicationName)"],
                    shortTitle: "Следующий", systemImageName: "forward.fill")
        AppShortcut(intent: ToggleDJIntent(),
                    phrases: ["DJ-режим в \(.applicationName)", "Включи диджей в \(.applicationName)"],
                    shortTitle: "DJ-режим", systemImageName: "dial.medium.fill")
    }
}
