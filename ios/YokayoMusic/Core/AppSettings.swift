import SwiftUI

/// Настройки приложения (UserDefaults).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("quality") var quality: Int = 320 { willSet { objectWillChange.send() } }          // по Wi-Fi
    @AppStorage("qualityCellular") var qualityCellular: Int = 192 { willSet { objectWillChange.send() } }
    @AppStorage("eqCustom") var eqCustomRaw: String = "0,0,0,0,0,0,0,0,0,0" { willSet { objectWillChange.send() } }
    @AppStorage("crossfade") var crossfade: Double = 0 { willSet { objectWillChange.send() } }     // сек, без DJ

    /// Качество для текущей сети.
    var streamQuality: Int { NetworkStatus.shared.isExpensive ? qualityCellular : quality }

    var customEQ: [Float] {
        get {
            let v = eqCustomRaw.split(separator: ",").compactMap { Float($0) }
            return v.count == 10 ? v : Array(repeating: 0, count: 10)
        }
        set { eqCustomRaw = newValue.map { String(format: "%.1f", $0) }.joined(separator: ",") }
    }
    @AppStorage("showExplicit") var showExplicit: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("animatedCovers") var animatedCovers: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("lockFullScreen") var lockFullScreen: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("eqPreset") var eqPreset: String = EQPreset.flat.rawValue { willSet { objectWillChange.send() } }
    @AppStorage("normalize") var normalize: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("particles") var particles: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("onboarded") var onboarded: Bool = false { willSet { objectWillChange.send() } }

    // DJ-режим
    @AppStorage("dj.enabled") var djEnabled: Bool = false { willSet { objectWillChange.send() } }
    @AppStorage("dj.beats") var djBeats: Int = 32 { willSet { objectWillChange.send() } }
    @AppStorage("dj.fx") var djFX: Double = 0.6 { willSet { objectWillChange.send() } }
    @AppStorage("dj.mode") var djMode: String = "ai" { willSet { objectWillChange.send() } }   // ai | classic
    @AppStorage("dj.smartOrder") var djSmartOrder: Bool = false { willSet { objectWillChange.send() } }
    @AppStorage("dj.tempoGlide") var djTempoGlide: Bool = true { willSet { objectWillChange.send() } }
}
