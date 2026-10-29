import AVFoundation

/// Эквалайзер на общем выходе: 10 полос, готовые пресеты и свой.
enum EQPreset: String, CaseIterable, Identifiable {
    case flat, bass, deepBass, vocal, electronic, hiphop, rock, acoustic, treble, night, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flat: "Обычный"
        case .bass: "Больше баса"
        case .deepBass: "Глубокий бас"
        case .vocal: "Вокал"
        case .electronic: "Электроника"
        case .hiphop: "Хип-хоп"
        case .rock: "Рок"
        case .acoustic: "Акустика"
        case .treble: "Звонкий"
        case .night: "Тише ночью"
        case .custom: "Свой"
        }
    }
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    /// Усиление полос, дБ (для «Своего» — из настроек).
    var gains: [Float] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: [6, 5, 4, 2, 0, 0, 0, 0, 1, 1]
        case .deepBass: [8, 7, 4, 0, -1, 0, 0, 0, 0, 0]
        case .vocal: [-2, -2, -1, 1, 3, 4, 3, 2, 0, -1]
        case .electronic: [5, 4, 2, 0, -2, 0, 1, 2, 4, 4]
        case .hiphop: [5, 5, 3, 1, -1, -1, 1, 1, 2, 2]
        case .rock: [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]
        case .acoustic: [3, 2, 2, 1, 1, 1, 2, 3, 2, 1]
        case .treble: [-2, -1, 0, 0, 0, 1, 3, 5, 6, 6]
        case .night: [-5, -4, -2, 0, 1, 1, 1, -1, -3, -4]
        case .custom: AppSettings.shared.customEQ
        }
    }
    /// «Тише ночью» дополнительно сжимает громкость.
    var globalGain: Float { self == .night ? -4 : 0 }
}

enum Equalizer {
    static func make() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: EQPreset.frequencies.count)
        for (i, f) in EQPreset.frequencies.enumerated() {
            let b = eq.bands[i]
            b.filterType = i == 0 ? .lowShelf : i == EQPreset.frequencies.count - 1 ? .highShelf : .parametric
            b.frequency = f
            b.bandwidth = 1.0
            b.bypass = false
            b.gain = 0
        }
        return eq
    }

    static func apply(_ preset: EQPreset, to eq: AVAudioUnitEQ) {
        apply(gains: preset.gains, global: preset.globalGain, to: eq)
    }

    static func apply(gains: [Float], global: Float = 0, to eq: AVAudioUnitEQ) {
        for (i, g) in gains.prefix(eq.bands.count).enumerated() { eq.bands[i].gain = g }
        eq.globalGain = global - max(0, gains.max() ?? 0) * 0.5   // запас, чтобы не клиповало
    }
}
