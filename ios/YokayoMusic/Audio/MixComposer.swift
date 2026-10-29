import Foundation

/// Сценарий перехода: кривые параметров обеих дек по долям A и разовые эффекты.
struct MixScript: Equatable {
    /// Кривая значения по долям: точки и линейная (или логарифмическая для частот) интерполяция.
    struct Lane: Equatable {
        var pts: [Double] = [0]
        var vals: [Float]
        var log = false

        init(_ v: Float, log: Bool = false) { vals = [v]; self.log = log }

        func at(_ x: Double) -> Float {
            guard let i = pts.firstIndex(where: { $0 > x }) else { return vals[vals.count - 1] }
            if i == 0 { return vals[0] }
            let t = Float((x - pts[i - 1]) / max(1e-6, pts[i] - pts[i - 1]))
            let a = vals[i - 1], b = vals[i]
            return log ? a * pow(b / a, t) : a + (b - a) * t
        }

        /// От текущего значения к `v` между долями `start` и `end`; всё, что было после `start`, заменяется.
        /// `shape` — изгиб: 1 — прямая, меньше — быстро в начале, больше — быстро в конце.
        mutating func ramp(to v: Float, from start: Double, to end: Double, shape: Double = 1) {
            let v0 = at(start)
            while let l = pts.last, l > start, pts.count > 1 { pts.removeLast(); vals.removeLast() }
            if pts.last! < start { pts.append(start); vals.append(v0) } else { vals[vals.count - 1] = v0 }
            let steps = shape == 1 ? 1 : 8
            for k in 1...steps {
                let t = Double(k) / Double(steps)
                pts.append(start + (end - start) * t)
                let f = Float(pow(t, shape))
                vals.append(log ? v0 * pow(v / v0, f) : v0 + (v - v0) * f)
            }
        }
    }

    struct DeckLanes: Equatable {
        var vol = Lane(1)                  // громкость 0…1
        var gain = Lane(0)                 // дБ до эха и реверба: −96 — дорожка смолкла, хвост эффектов звучит
        var bass = Lane(0)                 // дБ
        var mid = Lane(0)                  // дБ, середина (голос)
        var hp = Lane(20, log: true)       // Гц, ≤ 21 — выключен
        var lp = Lane(20000, log: true)    // Гц, ≥ 19500 — выключен
        var echo = Lane(0)                 // % влажности
        var reverb = Lane(0)               // %
    }

    enum Synth: Equatable { case riser, snareRoll, impact, crash, downlifter, subDrop }

    enum Event: Equatable {
        case synth(Synth, at: Double, beats: Double)
        case roll(at: Double, beats: Double)       // заикание бита A
        case gate(at: Double, beats: Double)       // нарезка A на восьмые
        case brake(at: Double, beats: Double)      // стоп-пластинка
        case spin(at: Double, beats: Double)       // перемотка назад
    }

    var a = DeckLanes()
    var b = DeckLanes()
    var events: [Event] = []
    var total: Double                // долей A во всём переходе
    var swap: Double                 // доля смены трека
    var bEnter: Double               // доля, с которой играет B
    var echoBeats = 0.75
    var echoFeedback: Float = 50

    var blend: Bool { bEnter < swap }
}

/// ИИ-композитор переходов. Каждый переход собирается заново из отдельных приёмов
/// (вход B, обмен басами, уход A, эффекты, длина): сотни вариантов «проигрываются в уме»
/// по энергии и басу обоих треков, оцениваются — бас не должен наслаиваться, громкость
/// не должна проваливаться, стиль должен подходить треку — и с поправкой на новизну и
/// на то, что нравится слушателю (MixBrain), выбирается один из лучших.
enum MixComposer {
    struct Recipe: Equatable {
        enum Entry: Int, CaseIterable { case fade, filterOpen, lowpassRise, cut }
        enum Exit: Int, CaseIterable { case bassKill, lowpassDown, echo, reverbWash, brake, backspin, roll, gate, fade }
        enum Swap: Int, CaseIterable { case bassSwap, gradualBass, hardCut, silenceDrop }
        enum FX: Int, CaseIterable { case none, riser, snareRoll, riserImpact, crash, downlifter, subDrop }

        var overlapBars: Int       // 0 — без наложения, B входит на смене
        var preBars: Int           // без наложения: сколько тактов A уходит до смены
        var tailBars: Int
        var entry: Entry
        var exit: Exit
        var swap: Swap
        var fx: FX
        var midCut: Bool
        var shape: Double
        var bFromDrop: Bool
        var hot = false            // для MixBrain: B с мощным дропом
        var chill = false          // спокойная пара

        var buffered: Bool { [.brake, .backspin, .roll, .gate].contains(exit) }
        var ends: Bool { swap == .hardCut || swap == .silenceDrop }
        var overlapBucket: Int { [0, 2, 4, 8, 16].firstIndex(of: overlapBars) ?? 2 }
        var signature: [Int] { [entry.rawValue, exit.rawValue, swap.rawValue, fx.rawValue, overlapBucket] }
    }

    private struct Ctx {
        let a: TrackAnalysis, b: TrackAnalysis
        let synced, keysFit, hot, chill, hiphop, longBlend, gridA: Bool
        let intro: Int
    }

    static let candidates = 320

    static func compose(a: TrackAnalysis, b: TrackAnalysis, rateA: Double, ratio: Double,
                        titleA: String, titleB: String, now: Double, start: Double? = nil) -> MixPlan {
        let gridOK = a.confidence >= 0.5 && b.confidence >= 0.5
        let keyDist = TrackAnalysis.keyDistance(a, b)
        let bpmA = a.bpm * rateA
        let hot = b.dropJump >= 1.5
        let outroE = a.meanBarEnergy(a.outroStartBar - 4, a.outroStartBar)
        let introE = b.meanBarEnergy(0, max(1, b.introEndBar))
        let ctx = Ctx(a: a, b: b, synced: abs(ratio - 1) <= 0.08 && gridOK, keysFit: (keyDist ?? 1) <= 1, hot: hot,
                      chill: !hot && (bpmA < 100 || (outroE < 0.45 && introE < 0.45)),
                      hiphop: bpmA < 105 && b.bpm < 105, longBlend: b.introEndBar >= 8 && a.outroFound,
                      gridA: a.confidence >= 0.4, intro: b.introEndBar)

        let history = MixBrain.shared.history
        var scored: [(Recipe, Double)] = []
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<candidates {
            let r = random(ctx, urgent: start != nil, &rng)
            scored.append((r, score(r, ctx, history: history, &rng)))
        }
        scored.sort { $0.1 > $1.1 }
        // не всегда первый: мягкий выбор среди пяти лучших — так сеты не повторяются
        let top = Array(scored.prefix(5))
        let weights = top.map { exp(($0.1 - top[0].1) / 0.15) }
        var pick = Double.random(in: 0..<weights.reduce(0, +), using: &rng)
        var chosen = top[0].0
        for (i, w) in weights.enumerated() { pick -= w; if pick <= 0 { chosen = top[i].0; break } }

        return plan(chosen, ctx, bpmA: bpmA, ratio: ratio, keyDist: keyDist, titleA: titleA, titleB: titleB, now: now, start: start)
    }

    // MARK: Случайный рецепт

    private static func random(_ c: Ctx, urgent: Bool, _ g: inout SystemRandomNumberGenerator) -> Recipe {
        let blend = c.synced && Double.random(in: 0..<1, using: &g) < 0.72
        var r = Recipe(overlapBars: 0, preBars: [1, 2].randomElement(using: &g)!, tailBars: [1, 2, 4].randomElement(using: &g)!,
                       entry: .cut, exit: .echo, swap: .hardCut, fx: Recipe.FX.allCases.randomElement(using: &g)!,
                       midCut: Bool.random(using: &g), shape: [0.6, 1, 1.7].randomElement(using: &g)!,
                       bFromDrop: Bool.random(using: &g), hot: c.hot, chill: c.chill)
        if blend {
            r.overlapBars = (urgent ? [2, 4] : [2, 4, 8, 16]).randomElement(using: &g)!
            r.entry = [.fade, .filterOpen, .lowpassRise].randomElement(using: &g)!
            r.exit = Recipe.Exit.allCases.filter { c.gridA || ![.roll, .gate].contains($0) }.randomElement(using: &g)!
            r.swap = r.buffered ? [.hardCut, .silenceDrop].randomElement(using: &g)! : Recipe.Swap.allCases.randomElement(using: &g)!
        } else {
            r.exit = [Recipe.Exit.echo, .reverbWash, .brake, .backspin, .lowpassDown, .fade, .roll, .gate]
                .filter { c.gridA || ![.roll, .gate].contains($0) }.randomElement(using: &g)!
            r.swap = [.hardCut, .silenceDrop].randomElement(using: &g)!
            if urgent { r.preBars = 1 }
        }
        return r
    }

    // MARK: Сценарий из рецепта

    private static func script(_ r: Recipe, beat: Double) -> MixScript {
        let S = Double(r.overlapBars > 0 ? r.overlapBars * 4 : r.preBars * 4)
        let tail = r.ends ? ([.echo, .reverbWash].contains(r.exit) ? 8.0 : 2.0) : Double(max(r.tailBars, [.echo, .reverbWash].contains(r.exit) ? 2 : 1) * 4)
        let T = S + tail
        var s = MixScript(total: T, swap: S, bEnter: r.overlapBars > 0 ? 0 : S)
        s.echoBeats = [0.75, 0.5, 1].randomElement()!
        s.echoFeedback = Float.random(in: 40...62)
        let sh = r.shape

        // Вход B
        switch r.entry {
        case .fade:
            s.b.vol = .init(0); s.b.vol.ramp(to: 1, from: 0, to: min(S, 16), shape: sh)
            s.b.bass = .init(-26)
        case .filterOpen:
            s.b.vol = .init(0); s.b.vol.ramp(to: 1, from: 0, to: min(S, 8))
            s.b.hp = .init(1400, log: true); s.b.hp.ramp(to: 20, from: 0, to: S, shape: sh)
            s.b.bass = .init(-26)
        case .lowpassRise:
            s.b.vol = .init(0); s.b.vol.ramp(to: 1, from: 0, to: min(S, 8))
            s.b.lp = .init(260, log: true); s.b.lp.ramp(to: 20000, from: 0, to: S, shape: sh)
            s.b.bass = .init(-26)
        case .cut:
            break
        }

        // Голос A уступает место, пока играют оба
        if r.overlapBars > 0, r.midCut { s.a.mid.ramp(to: -9, from: S * 0.5, to: S) }

        // Где A смолкает
        let cutAt = r.swap == .silenceDrop ? S - 1 : S
        let fxLen: Double = switch r.exit { case .roll: min(4, cutAt); case .gate: min(8, cutAt); case .brake: 2; case .backspin: min(4, cutAt); default: 0 }
        let goneAt = r.buffered ? cutAt - fxLen : cutAt

        // Уход A
        switch r.exit {
        case .bassKill:
            if r.ends { s.a.hp.ramp(to: 420, from: max(0, S - 8), to: cutAt, shape: sh) }
            else { s.a.hp.ramp(to: 750, from: S, to: T, shape: sh); s.a.vol.ramp(to: 0, from: S, to: T, shape: 1.6) }
        case .lowpassDown:
            s.a.lp.ramp(to: 420, from: max(0, r.ends ? cutAt - 8 : S * 0.4), to: r.ends ? cutAt : S, shape: sh)
            if !r.ends { s.a.vol.ramp(to: 0, from: S, to: T) }
        case .echo:
            let e0 = r.ends ? max(0, cutAt - 4) : S + (T - S) * 0.25
            s.a.echo.ramp(to: 65, from: e0, to: r.ends ? cutAt : S + (T - S) * 0.6)
            s.a.hp.ramp(to: 260, from: e0, to: r.ends ? cutAt : T)
            if !r.ends { s.a.gain.ramp(to: -96, from: S + (T - S) * 0.6, to: S + (T - S) * 0.7) }
        case .reverbWash:
            let w0 = r.ends ? max(0, cutAt - 4) : S
            s.a.reverb.ramp(to: 85, from: w0, to: r.ends ? cutAt : S + (T - S) * 0.5)
            if !r.ends { s.a.gain.ramp(to: -96, from: S + (T - S) * 0.5, to: S + (T - S) * 0.6) }
        case .fade:
            if r.ends { s.a.vol.ramp(to: 0, from: max(0, cutAt - 8), to: cutAt, shape: sh) }
            else { s.a.vol.ramp(to: 0, from: S - min(S, 4), to: T, shape: sh) }
        case .brake:
            s.events.append(.brake(at: goneAt, beats: fxLen))
        case .backspin:
            s.events.append(.spin(at: goneAt, beats: fxLen))
        case .roll:
            s.events.append(.roll(at: goneAt, beats: fxLen))
        case .gate:
            s.events.append(.gate(at: goneAt, beats: fxLen))
        }

        // Смена
        switch r.swap {
        case .bassSwap:
            s.b.bass.ramp(to: 0, from: S, to: S + 1)
            s.a.bass.ramp(to: -26, from: S, to: S + 1)
        case .gradualBass:
            let h = min(4, S / 2)
            s.b.bass.ramp(to: 0, from: S - h, to: S + h)
            s.a.bass.ramp(to: -26, from: S - h, to: S + h)
        case .hardCut, .silenceDrop:
            if goneAt > 0 { s.a.gain.ramp(to: -96, from: goneAt - 0.06, to: goneAt) } else { s.a.gain = .init(-96) }
            s.b.bass.ramp(to: 0, from: S - 0.05, to: S)
            if r.swap == .silenceDrop, r.overlapBars > 0 {
                s.b.gain.ramp(to: -60, from: cutAt - 0.06, to: cutAt)
                s.b.gain.ramp(to: 0, from: S - 0.03, to: S)
            }
        }
        // B к смене полностью открыт
        if r.entry != .cut { s.b.vol.ramp(to: 1, from: max(0, S - 0.5), to: S) }

        // Эффекты поверх
        let riserLen = min(S >= 8 ? 8 : 4, max(2, S))
        switch r.fx {
        case .none: break
        case .riser: s.events.append(.synth(.riser, at: S - riserLen * (S >= 16 ? 2 : 1), beats: riserLen * (S >= 16 ? 2 : 1)))
        case .snareRoll: s.events.append(.synth(.snareRoll, at: S - riserLen, beats: riserLen))
        case .riserImpact:
            s.events.append(.synth(.riser, at: S - riserLen, beats: riserLen))
            s.events.append(.synth(.impact, at: S, beats: 4))
        case .crash: s.events.append(.synth(.crash, at: S, beats: 4))
        case .downlifter: s.events.append(.synth(.downlifter, at: S, beats: 8))
        case .subDrop: s.events.append(.synth(.subDrop, at: S, beats: 4))
        }
        return s
    }

    // MARK: Оценка

    private static func dbLin(_ db: Float) -> Float { db <= -90 ? 0 : pow(10, db / 20) }

    private static func score(_ r: Recipe, _ c: Ctx, history: [[Int]], _ g: inout SystemRandomNumberGenerator) -> Double {
        let s = script(r, beat: c.a.beat)
        let T = s.total, S = s.swap
        let aBar0 = max(0, c.a.outroStartBar - Int(S / 4))
        let bBar0 = r.overlapBars > 0 ? max(0, c.intro - r.overlapBars) : (r.bFromDrop && c.intro > 0 ? c.intro : 0)
        func bar(_ arr: [Float], _ i: Int) -> Float { arr.isEmpty ? 0.6 : arr[max(0, min(arr.count - 1, i))] }
        let aRef = c.a.meanBarEnergy(aBar0 - 4, aBar0), bRef = c.b.meanBarEnergy(bBar0 + Int(T / 4), bBar0 + Int(T / 4) + 8)

        var clash = 0.0, hole = 0.0, loud = 0.0, voice = 0.0, tailE: Float = 0
        let bufferSpan: ClosedRange<Double>? = s.events.compactMap { e -> ClosedRange<Double>? in
            switch e { case .roll(let x, let n), .gate(let x, let n), .brake(let x, let n), .spin(let x, let n): return x...(x + n); default: return nil }
        }.first
        var x = 0.0
        while x < T {
            let ia = aBar0 + Int(x / 4)
            let aE = bar(c.a.barEnergy, ia), aL = bar(c.a.barLow, ia)
            let gA = s.a.vol.at(x) * dbLin(s.a.gain.at(x))
            var aFull = aE * gA * (s.a.lp.at(x) < 2000 ? s.a.lp.at(x) / 2000 : 1)
            var aLow = aL * gA * dbLin(s.a.bass.at(x)) * min(1, 80 / s.a.hp.at(x))
            if let sp = bufferSpan, sp.contains(x) { aFull = aE * 0.8; aLow = aL * 0.5 }
            tailE = max(tailE * 0.82, aE * (s.a.echo.at(x) + s.a.reverb.at(x)) / 100)
            var bFull: Float = 0, bLow: Float = 0
            if x >= s.bEnter {
                let ib = bBar0 + Int((x - s.bEnter) / 4)
                let gB = s.b.vol.at(x) * dbLin(s.b.gain.at(x))
                bFull = bar(c.b.barEnergy, ib) * gB * (s.b.lp.at(x) < 2000 ? s.b.lp.at(x) / 2000 : 1) * min(1, 800 / max(800, s.b.hp.at(x)) + 0.3)
                bLow = bar(c.b.barLow, ib) * gB * dbLin(s.b.bass.at(x)) * min(1, 80 / s.b.hp.at(x))
            }
            clash += Double(max(0, min(aLow, bLow) - 0.22))
            let L = Double(aFull + bFull + tailE * 0.3)
            let target = Double(aRef + (bRef - aRef) * Float(x / T))
            let silent = r.swap == .silenceDrop && x >= S - 1 && x < S
            if !silent { hole += max(0, 0.5 * target - L) }
            loud += max(0, L - 1.3 * max(target, 0.35))
            voice += Double(max(0, min(aFull * dbLin(s.a.mid.at(x)), bFull) - 0.3))
            x += 0.5
        }
        let n = T * 2
        var sc = -(clash / n) * 6 - (hole / n) * 5 - (loud / n) * 3 - (voice / n) * (c.keysFit ? 1.5 : 4)

        // стиль
        let impacty: Set<Recipe.FX> = [.riserImpact, .subDrop, .crash]
        let trick: Set<Recipe.Exit> = [.roll, .gate, .brake, .backspin]
        let smooth: Set<Recipe.Exit> = [.reverbWash, .fade, .echo, .lowpassDown]
        if c.hot {
            if [.riser, .snareRoll, .riserImpact].contains(r.fx) { sc += 0.5 }
            if r.swap == .silenceDrop { sc += 0.2 }
            if r.overlapBars == 0 && r.bFromDrop { sc += 0.3 }
        }
        if c.chill {
            if impacty.contains(r.fx) || r.fx == .snareRoll { sc -= 0.7 }
            if trick.contains(r.exit) { sc -= 0.6 }
            if smooth.contains(r.exit) { sc += 0.35 }
            if r.overlapBars >= 8 { sc += 0.35 }
        }
        if c.hiphop {
            if [.backspin, .brake].contains(r.exit) { sc += 0.3 }
            if r.fx == .subDrop { sc += 0.25 }
            if r.overlapBars >= 8 { sc -= 0.3 }
        }
        if c.longBlend && r.overlapBars >= 8 { sc += 0.45 }
        if !c.longBlend && r.overlapBars >= 8 { sc -= 0.5 }
        if !c.keysFit && r.overlapBars >= 8 { sc -= 0.6 }
        if r.overlapBars > max(4, c.intro) { sc -= 0.12 * Double(r.overlapBars - max(4, c.intro)) }

        // новизна: недавние переходы не повторяем
        for (i, h) in history.reversed().enumerated() {
            let same = zip(h, r.signature).filter { $0 == $1 }.count
            sc -= 1.3 * pow(Double(same) / 5, 2) * pow(0.8, Double(i))
            if i == 0 && h.count > 1 && h[1] == r.exit.rawValue { sc -= 0.5 }
        }
        // вкус слушателя
        sc += 1.4 * (MixBrain.shared.like(r) - 0.5)
        // немного свободы
        sc += Double.random(in: -0.12...0.12, using: &g)
        return sc
    }

    // MARK: План

    private static func plan(_ r: Recipe, _ c: Ctx, bpmA: Double, ratio: Double, keyDist: Int?,
                             titleA: String, titleB: String, now: Double, start: Double?) -> MixPlan {
        let a = c.a, b = c.b
        let sc = script(r, beat: a.beat)
        let sBars = Int(sc.swap / 4)

        // B: при наложении — так, чтобы его дроп пришёлся на смену; без наложения — с дропа или с начала
        let bStart: Double
        if r.overlapBars > 0 {
            let bStartBar = c.intro >= r.overlapBars ? c.intro - r.overlapBars : 0
            bStart = bStartBar == 0 && c.intro == 0 ? b.mixIn : b.time(ofBar: bStartBar)
        } else {
            bStart = r.bFromDrop && c.intro > 0 && c.intro <= 32 ? b.time(ofBar: c.intro) : b.mixIn
        }

        // A: смена на начале аутро (граница фразы), переход успевает до конца
        let aStart: Double
        if let start {
            aStart = start
        } else {
            let lastBar = a.lastSoundBar
            let tailBars = Int(((sc.total - sc.swap) / 4).rounded(.up))
            var swapBar = a.outroStartBar
            if swapBar + tailBars > lastBar { swapBar = lastBar - tailBars }
            swapBar = max(swapBar, a.bar(at: now) + 2 + sBars)
            aStart = a.time(ofBar: max(0, swapBar - sBars))
        }

        let tA = "«\(titleA)»", tB = "«\(titleB)»"
        let entryText: String = switch r.entry {
        case .fade: "\(tB) входит без баса и набирает громкость"
        case .filterOpen: "\(tB) раскрывается из высокочастотного фильтра"
        case .lowpassRise: "\(tB) поднимается из-под глухого фильтра"
        case .cut: ""
        }
        let exitText: String = switch r.exit {
        case .bassKill: "\(tA) теряет низ и уходит в фильтр"
        case .lowpassDown: "\(tA) глохнет в низкочастотном фильтре"
        case .echo: "\(tA) улетает в эхо"
        case .reverbWash: "\(tA) растворяется в реверберации"
        case .brake: "стоп-пластинка на \(tA)"
        case .backspin: "перемотка \(tA) назад"
        case .roll: "бит \(tA) заикается всё быстрее"
        case .gate: "\(tA) режется на восьмые"
        case .fade: "\(tA) плавно гаснет"
        }
        let swapText: String = switch r.swap {
        case .bassSwap: "обмен басами"
        case .gradualBass: "бас плавно переходит к \(tB)"
        case .hardCut: "резкая смена на сильную долю"
        case .silenceDrop: "доля тишины — и дроп \(tB)"
        }
        let fxText: String? = switch r.fx {
        case .none: nil
        case .riser: "райзер"
        case .snareRoll: "снейр-ролл"
        case .riserImpact: "райзер и удар"
        case .crash: "тарелка на смене"
        case .downlifter: "«выдох» после смены"
        case .subDrop: "саб-дроп"
        }
        let exitTitle: String = switch r.exit {
        case .bassKill: "Фильтр-уход"; case .lowpassDown: "Глухой фильтр"; case .echo: "Эхо"; case .reverbWash: "Растворение"
        case .brake: "Стоп-пластинка"; case .backspin: "Перемотка"; case .roll: "Бит-ролл"; case .gate: "Нарезка"; case .fade: "Плавный микс"
        }

        var steps: [String] = []
        if r.overlapBars > 0 {
            steps.append("Такт 1: \(entryText)\(r.midCut ? ", голос \(tA) отходит назад" : "")")
            if r.buffered { steps.append("Последние доли перед сменой: \(exitText)") }
            steps.append("Такт \(sBars + 1): \(swapText)\(fxText.map { " · \($0)" } ?? "")")
            if !r.buffered { steps.append("Дальше: \(exitText)") }
        } else {
            steps.append((sBars > 1 ? "Такты 1–\(sBars)" : "Такт 1") + ": \(exitText)")
            steps.append("Такт \(sBars + 1): \(swapText) — \(tB) \(bStart > b.mixIn + 1 ? "сразу с дропа" : "с начала")\(fxText.map { " · \($0)" } ?? "")")
        }

        let tempoText = abs(ratio - 1) < 0.005 ? "темп совпадает (\(Int(bpmA.rounded())) BPM)"
            : c.synced ? "подгоню темп \(tB) на \(String(format: "%+.1f%%", (ratio - 1) * 100))"
            : "темпы \(Int(bpmA.rounded()))→\(Int(b.bpm.rounded())) не сводятся — смена без наложения"
        let keyText: String = {
            guard let ca = a.camelot, let cb = b.camelot else { return "" }
            return c.keysFit ? "; \(ca)→\(cb) гармонично" : "; \(ca)→\(cb) конфликтуют"
        }()
        let mood = c.hot ? "; у \(tB) мощный дроп" : c.chill ? "; спокойная пара" : ""

        var m = MixPlan(technique: .composed, aStart: aStart, bStart: bStart,
                        overlapBeats: sc.swap, tailBeats: sc.total - sc.swap, synced: c.synced,
                        riser: false, impact: false, echoTail: 0,
                        headline: "\(exitTitle) · " + (r.overlapBars > 0 ? "\(r.overlapBars) \(r.overlapBars < 5 ? "такта" : "тактов")" : "на сильную долю"),
                        reason: "\(tempoText)\(keyText)\(mood); собран из \(candidates) вариантов",
                        steps: steps, variantTitle: "ИИ")
        m.script = sc
        m.recipe = r
        return m
    }
}

/// Вкус слушателя: маленькая логистическая модель, которая учится прямо на телефоне.
/// Переход, после которого трек пропустили в первые 20 секунд, — «не понравился»;
/// дослушали дальше 45 секунд — «понравился». Ещё — 👍/👎 в DJ-лаборатории.
final class MixBrain {
    static let shared = MixBrain()
    private let wKey = "mixbrain.w", hKey = "mixbrain.history"
    private(set) var w: [Double]
    private(set) var history: [[Int]]
    private var pending: (r: MixComposer.Recipe, at: Date)?

    private static let dim = 1 + 4 + 9 + 4 + 7 + 5 + 1 + 9 + 7

    private init() {
        let saved = UserDefaults.standard.array(forKey: wKey) as? [Double] ?? []
        w = saved.count == Self.dim ? saved : Array(repeating: 0, count: Self.dim)
        history = UserDefaults.standard.array(forKey: hKey) as? [[Int]] ?? []
    }

    private func features(_ r: MixComposer.Recipe) -> [Double] {
        var f = Array(repeating: 0.0, count: Self.dim)
        var o = 0
        func one(_ i: Int, _ n: Int, _ v: Double = 1) { f[o + i] = v; o += n }
        one(0, 1)
        one(r.entry.rawValue, 4)
        one(r.exit.rawValue, 9)
        one(r.swap.rawValue, 4)
        one(r.fx.rawValue, 7)
        one(r.overlapBucket, 5)
        one(0, 1, r.midCut ? 1 : 0)
        one(r.exit.rawValue, 9, r.chill ? 1 : 0)
        one(r.fx.rawValue, 7, r.hot ? 1 : 0)
        return f
    }

    /// Вероятность, что переход понравится (0…1).
    func like(_ r: MixComposer.Recipe) -> Double {
        let z = zip(w, features(r)).reduce(0) { $0 + $1.0 * $1.1 }
        return 1 / (1 + exp(-z))
    }

    func learn(_ r: MixComposer.Recipe, good: Bool, strength: Double = 1) {
        let f = features(r)
        let err = (good ? 1 : 0) - like(r)
        for i in w.indices { w[i] += 0.35 * strength * err * f[i] - 0.002 * w[i] }
        UserDefaults.standard.set(w, forKey: wKey)
    }

    func began(_ r: MixComposer.Recipe) {
        history.append(r.signature)
        if history.count > 8 { history.removeFirst(history.count - 8) }
        UserDefaults.standard.set(history, forKey: hKey)
    }

    func finished(_ r: MixComposer.Recipe) { pending = (r, Date()) }

    /// Пользователь сам переключил трек.
    func userSkipped() {
        guard let p = pending else { return }
        pending = nil
        if Date().timeIntervalSince(p.at) < 20 { learn(p.r, good: false) }
    }

    func tick() {
        guard let p = pending, Date().timeIntervalSince(p.at) > 45 else { return }
        pending = nil
        learn(p.r, good: true, strength: 0.5)
    }
}
