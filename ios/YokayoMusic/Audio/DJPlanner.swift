import Foundation

/// План перехода: что и в какой такт делает каждая дека.
struct MixPlan: Equatable {
    enum Technique: String { case bassSwap, filterSwap, echoOut, backspin, fade, composed }

    var technique: Technique
    var aStart: Double          // сек файла A: сильная доля, с которой начинается переход
    var bStart: Double          // сек файла B: откуда играет B
    var overlapBeats: Double    // долей A от начала перехода до смены (дроп B / обмен басами)
    var tailBeats: Double       // долей после смены, пока A уходит
    var synced: Bool            // B подстроен по темпу и долям
    var riser: Bool
    var impact: Bool
    var echoTail: Float         // эхо на уходе A, 0…1
    var headline: String
    var reason: String
    var steps: [String]
    var variantTitle: String
    var script: MixScript? = nil            // сценарий ИИ-композитора
    var recipe: MixComposer.Recipe? = nil

    var totalBeats: Double { overlapBeats + tailBeats }
    var swapAt: Double { overlapBeats / totalBeats }
    var overlapping: Bool { if let script { return script.blend }; return technique == .bassSwap || technique == .filterSwap || technique == .fade }
}

/// Диджей-планировщик: «Классика» — один предсказуемый переход, режим ИИ — MixComposer.
enum DJPlanner {
    static let variants = 3

    /// Насколько хорошо B сводится после A (0…1): темп, тональность, надёжность сетки.
    /// По нему умная очередь выбирает следующий трек.
    static func compatibility(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Double {
        let mult = [1.0, 2, 0.5].min { abs(a.bpm / (b.bpm * $0) - 1) < abs(a.bpm / (b.bpm * $1) - 1) }!
        let dev = abs(a.bpm / (b.bpm * mult) - 1)
        let tempo = dev <= 0.08 ? 1 - dev / 0.08 * 0.6 : max(0, 0.3 - dev)
        let key: Double = switch TrackAnalysis.keyDistance(a, b) { case 0: 1; case 1: 0.85; case 2: 0.5; case nil: 0.6; default: 0.25 }
        let grid = min(a.confidence, b.confidence)
        return tempo * 0.55 + key * 0.3 + grid * 0.15
    }

    /// Простой кроссфейд без DJ-режима: последние `seconds` секунд трека.
    static func crossfade(a: TrackAnalysis?, duration: Double, seconds: Double, bStart: Double) -> MixPlan {
        let end = a.map { min($0.lastSound, duration) } ?? duration
        return MixPlan(technique: .fade, aStart: max(0, end - seconds), bStart: bStart, overlapBeats: seconds * 0.5, tailBeats: seconds * 0.5,
                       synced: false, riser: false, impact: false, echoTail: 0, headline: "Кроссфейд \(Int(seconds)) с",
                       reason: "плавная смена треков", steps: [], variantTitle: "Кроссфейд")
    }

    static func plan(a: TrackAnalysis, b: TrackAnalysis, rateA: Double, titleA: String, titleB: String,
                     variant: Int, classic: Bool, beatsSetting: Int, now: Double, start: Double? = nil) -> MixPlan {
        let bpmA = a.bpm * rateA
        let mult = [1.0, 2, 0.5].min { abs(bpmA / (b.bpm * $0) - 1) < abs(bpmA / (b.bpm * $1) - 1) }!
        let ratio = bpmA / (b.bpm * mult)
        let gridOK = a.confidence >= 0.5 && b.confidence >= 0.5
        let tempoOK = abs(ratio - 1) <= 0.08 && gridOK

        let tA = "«\(titleA)»", tB = "«\(titleB)»"
        let tempoText = abs(ratio - 1) < 0.005
            ? "темп совпадает (\(Int(bpmA.rounded())) BPM)"
            : abs(ratio - 1) <= 0.08
            ? "темп \(Int(bpmA.rounded()))→\(Int((b.bpm * mult).rounded())) BPM, подгоню \(tB) на \(String(format: "%+.1f%%", (ratio - 1) * 100))"
            : "темп \(Int(bpmA.rounded()))→\(Int(b.bpm.rounded())) BPM"

        // Классика — как в первой версии: 8 тактов с обменом басами перед концом
        if classic {
            let beats = Double(beatsSetting)
            let start = a.mixOut(beats: Int(beats) + 16)
            if tempoOK || abs(ratio - 1) <= 0.10 {
                return MixPlan(technique: .bassSwap, aStart: start, bStart: b.mixIn, overlapBeats: beats / 2, tailBeats: beats / 2 + 4,
                               synced: true, riser: true, impact: true, echoTail: 0.35,
                               headline: "Классика · \(Int(beats / 4)) тактов",
                               reason: tempoText, steps: ["Сведение по битам, обмен басами в середине, уход в фильтр и эхо"], variantTitle: "Классика")
            }
            return echoPlan(a: a, b: b, now: now, tA: tA, tB: tB, reason: tempoText, hot: false, variantTitle: "Классика")
        }

        // TransitionNet: переход рисует нейросеть
        if AppSettings.shared.djMode == "tn",
           let m = MixComposer.composeNeural(a: a, b: b, rateA: rateA, ratio: ratio, titleA: titleA, titleB: titleB, now: now, start: start) {
            return m
        }
        // ИИ-композитор: каждый переход сочиняется заново из приёмов
        return MixComposer.compose(a: a, b: b, rateA: rateA, ratio: ratio, titleA: titleA, titleB: titleB, now: now, start: start)
    }

    /// Уход в эхо: A на границе фразы улетает в эхо и фильтр, B входит на сильную долю.
    private static func echoPlan(a: TrackAnalysis, b: TrackAnalysis, now: Double, tA: String, tB: String,
                                 reason: String, hot: Bool, spin: Bool = false, variantTitle: String) -> MixPlan {
        let lastBar = a.lastSoundBar
        var swapBar = min(a.outroStartBar, lastBar - 1)
        if swapBar - 2 < a.bar(at: now) + 1 { swapBar = min(lastBar, a.bar(at: now) + 3) }
        let aStart = a.time(ofBar: swapBar - 2)
        // энергичный B — сразу с дропа, спокойный — с начала
        let startAtDrop = hot && b.introEndBar > 0 && b.introEndBar <= 32
        let bStart = startAtDrop ? b.time(ofBar: b.introEndBar) : b.mixIn
        var steps = ["Такты 1–2: \(tA) уходит в фильтр и эхо", "Такт 3: \(tB) входит на сильную долю\(startAtDrop ? " — сразу с дропа" : "")"]
        if spin { steps[0] = "Такт 2: перемотка \(tA) назад" }
        return MixPlan(technique: spin ? .backspin : .echoOut, aStart: aStart, bStart: bStart,
                       overlapBeats: 8, tailBeats: 8, synced: false, riser: true, impact: startAtDrop || spin, echoTail: 0.55,
                       headline: spin ? "Перемотка и удар" : "Уход в эхо", reason: reason, steps: steps, variantTitle: variantTitle)
    }
}
