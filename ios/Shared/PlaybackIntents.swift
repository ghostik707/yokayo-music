import AppIntents

/// Действия с плеером из виджетов, Пункта управления, Siri и «Команд».
enum PlaybackAction: String {
    case toggle, next, previous, wave, djToggle, pause
}

/// Приложение подключает сюда свой плеер при запуске. В процессе виджета обработчика нет:
/// аудио-интенты система выполняет в процессе приложения.
@MainActor
enum PlaybackBridge {
    static var handler: ((PlaybackAction) async -> Void)?
    static func run(_ action: PlaybackAction) async { await handler?(action) }
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Играть или пауза"
    func perform() async throws -> some IntentResult { await PlaybackBridge.run(.toggle); return .result() }
}

struct PauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Пауза"
    func perform() async throws -> some IntentResult { await PlaybackBridge.run(.pause); return .result() }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Следующий трек"
    func perform() async throws -> some IntentResult { await PlaybackBridge.run(.next); return .result() }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Предыдущий трек"
    func perform() async throws -> some IntentResult { await PlaybackBridge.run(.previous); return .result() }
}

struct PlayWaveIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Моя волна"
    static let description = IntentDescription("Запускает «Мою волну» в Yokayo")
    func perform() async throws -> some IntentResult { await PlaybackBridge.run(.wave); return .result() }
}

struct ToggleDJIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "DJ-режим"
    static let description = IntentDescription("Включает или выключает DJ-сведение треков")
    func perform() async throws -> some IntentResult { await PlaybackBridge.run(.djToggle); return .result() }
}
