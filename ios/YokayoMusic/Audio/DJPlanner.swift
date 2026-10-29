import Foundation

/// План перехода: что и в какой такт делает каждая дека.
struct MixPlan: Equatable {
    enum Technique: String { case bassSwap, filterSwap, echoOut, backspin, fade }

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

    var totalBeats: Double { overlapBeats + tailBeats }
    var swapAt: Double { overlapBeats / totalBeats }
    var overlapping: Bool { technique == .bassSwap || technique == .filterSwap || technique == .fade }
}

/// Диджей-планировщик. Без случайностей: одна и та же пара всегда сводится одинаково.
/// Правила как у живого диджея: интро B ложится на аутро A, дроп B попадает
/// на границу фразы A, басы никогда не звучат вместе, при ненадёжной сетке или
/// несовместимом темпе — чистый уход в эхо вместо сведения по битам.
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
                     variant: Int, classic: Bool, beatsSetting: Int, now: Double) -> MixPlan {
        let bpmA = a.bpm * rateA
        let mult = [1.0, 2, 0.5].min { abs(bpmA / (b.bpm * $0) - 1) < abs(bpmA / (b.bpm * $1) - 1) }!
        let ratio = bpmA / (b.bpm * mult)
        let gridOK = a.confidence >= 0.5 && b.confidence >= 0.5
        let tempoOK = abs(ratio - 1) <= 0.08 && gridOK
        let keyDist = TrackAnalysis.keyDistance(a, b)
        let keysFit = (keyDist ?? 1) <= 1
        let v = variant % variants

        let tA = "«\(titleA)»", tB = "«\(titleB)»"
        let tempoText = abs(ratio - 1) < 0.005
            ? "темп совпадает (\(Int(bpmA.rounded())) BPM)"
            : abs(ratio - 1) <= 0.08
            ? "темп \(Int(bpmA.rounded()))→\(Int((b.bpm * mult).rounded())) BPM, подгоню \(tB) на \(String(format: "%+.1f%%", (ratio - 1) * 100))"
            : "темп \(Int(bpmA.rounded()))→\(Int(b.bpm.rounded())) BPM"
        let keyText: String = {
            guard let ca = a.camelot, let cb = b.camelot else { return "тональность не определил" }
            return keysFit ? "тональности \(ca)→\(cb) — гармонично" : "тональности \(ca)→\(cb) конфликтуют — наложение будет коротким"
        }()

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

        // Вариант 2 или нельзя сводить по битам — чистый уход в эхо
        if !tempoOK || v == 2 {
            let why = !gridOK ? "сетка битов у трека ненадёжна — сводить по долям не буду"
                : abs(ratio - 1) > 0.08 ? "\(tempoText) — слишком разный для сведения по битам, сменю через эхо на сильной доле" : "вариант «эхо»"
            let hiphop = bpmA < 105 && b.bpm < 105
            return echoPlan(a: a, b: b, now: now, tA: tA, tB: tB, reason: why, hot: b.dropJump > 1.5,
                            spin: hiphop && v == 2 && a.meanBarEnergy(a.outroStartBar - 4, a.outroStartBar) > 0.6,
                            variantTitle: v == 2 ? "Эхо" : "Лучший")
        }

        // Сведение по битам. Длинный микс — только когда есть куда класть: интро у B и аутро у A.
        // Иначе (рэп, поп без инструментальных хвостов) — короткий микс на 4 такта, чтобы куплеты не наслаивались.
        let intro = b.introEndBar
        let longBlend = intro >= 8 && a.outroFound
        var overlapBars = longBlend ? min(intro, 16) : 4
        var technique: MixPlan.Technique = .bassSwap
        if !longBlend { technique = .filterSwap }
        if !keysFit || v == 1 { overlapBars = min(overlapBars, longBlend ? 8 : 4); technique = .filterSwap }
        overlapBars = max(4, (overlapBars / 4) * 4)

        // B начинается так, чтобы его дроп пришёлся ровно на смену
        let bStartBar = intro >= overlapBars ? intro - overlapBars : 0
        let bDropBar = bStartBar + overlapBars
        let bStart = bStartBar == 0 && intro == 0 ? b.mixIn : b.time(ofBar: bStartBar)

        // Смена на A: начало его аутро (граница фразы), но так, чтобы переход успел до конца
        let lastBar = a.lastSoundBar
        let tailBars = technique == .bassSwap ? 4 : 2
        var swapBar = a.outroStartBar
        if swapBar + tailBars > lastBar { swapBar = lastBar - tailBars }
        if swapBar - overlapBars < a.bar(at: now) + 2 { swapBar = max(a.bar(at: now) + 2 + overlapBars, swapBar) }
        if swapBar + tailBars > lastBar + 2 {  // не помещается — короче
            overlapBars = max(4, lastBar - tailBars - a.bar(at: now) - 2)
            swapBar = lastBar - tailBars
        }
        let aStart = a.time(ofBar: swapBar - overlapBars)
        let riser = b.dropJump >= 1.5
        let impact = b.dropJump >= 1.9

        var steps: [String] = []
        if technique == .bassSwap {
            steps.append("Такт 1: \(tB) входит без баса под \(tA) и плавно набирает громкость")
            steps.append("Такт \(overlapBars + 1): \(bDropBar > 0 ? "дроп \(tB)" : "сильная доля") — меняю басы")
            steps.append("Такты \(overlapBars + 1)–\(overlapBars + tailBars): \(tA) уходит в фильтр")
        } else {
            steps.append("Такт 1: \(tB) открывается из фильтра, \(tA) уходит в глухой низ")
            steps.append("Такт \(overlapBars + 1): меняю басы, \(tA) гаснет")
        }
        if riser { steps.append("Последние такты перед дропом — райзер\(impact ? ", на дропе — удар" : "")") }

        return MixPlan(technique: technique, aStart: aStart, bStart: bStart,
                       overlapBeats: Double(overlapBars * 4), tailBeats: Double(tailBars * 4),
                       synced: true, riser: riser, impact: impact, echoTail: 0.18,
                       headline: technique == .bassSwap ? "Микс \(overlapBars) тактов · интро на аутро" : "Фильтр-микс \(overlapBars) тактов",
                       reason: "\(tempoText); \(keyText)\(longBlend ? "" : "; без длинного интро/аутро — короткий микс")", steps: steps,
                       variantTitle: v == 0 ? "Лучший" : "Короткий фильтр")
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
