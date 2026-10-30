import Foundation

/// Сценарий перехода: кривые параметров обеих дек по долям A и разовые эффекты.
struct MixScript: Equatable {
    /// Кривая значения по долям: точки и линейная (или логарифмическая для частот) интерполяция.
    struct Lane: Equatable {
        var pts: [Double] = [0]
        var vals: [Float]
        var log = false

        init(_ v: Float, log: Bool = false) { vals = [v]; self.log = log }
        init(pts: [Double], vals: [Float], log: Bool = false) { self.pts = pts; self.vals = vals; self.log = log }

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

        let result = plan(chosen, ctx, bpmA: bpmA, ratio: ratio, keyDist: keyDist, titleA: titleA, titleB: titleB, now: now, start: start)
        think(chosen, ctx, scored: scored, ratio: ratio, keyDist: keyDist, outroE: outroE, introE: introE, history: history, headline: result.headline, &rng)
        return result
    }

    /// Разбор оценки одного варианта — для визуализации «как думает ИИ».
    final class Parts { var clash = 0.0, hole = 0.0, loud = 0.0, voice = 0.0, style = 0.0, novelty = 0.0, like = 0.5 }

    /// Как ИИ пришёл к решению: входы, критерии оценки выбранного варианта, лучшие оценки по каждому приёму.
    struct Thought: Equatable {
        var inputs: [(String, Double)]
        var criteria: [(String, Double)]
        var outputs: [(String, Double)]
        var chosen: Int
        var headline: String
        var summary = ""
        var middleTitle = "Оценивает"
        var outputTitle = "Выбирает"
        var id = UUID()
        static func == (a: Thought, b: Thought) -> Bool { a.id == b.id }
    }

    static let exitNames = ["Фильтр-уход", "Глухой фильтр", "Эхо", "Растворение", "Стоп-пластинка", "Перемотка", "Бит-ролл", "Нарезка", "Плавный микс"]

    private static func think(_ chosen: Recipe, _ c: Ctx, scored: [(Recipe, Double)], ratio: Double, keyDist: Int?,
                              outroE: Float, introE: Float, history: [[Int]], headline: String, _ g: inout SystemRandomNumberGenerator) {
        let parts = Parts()
        _ = score(chosen, c, history: history, &g, parts: parts)
        func good(_ pen: Double, _ k: Double) -> Double { max(0, min(1, 1 - pen * k)) }
        let key: Double = switch keyDist { case 0: 1; case 1: 0.85; case 2: 0.5; case nil: 0.6; default: 0.25 }
        let inputs: [(String, Double)] = [
            ("Темп", c.synced ? max(0.15, 1 - abs(ratio - 1) / 0.08) : 0.1),
            ("Сетка битов", min(c.a.confidence, c.b.confidence)),
            ("Тональность", key),
            ("Энергия A", Double(outroE)),
            ("Энергия B", Double(introE)),
            ("Дроп B", Double(max(0, min(1, (c.b.dropJump - 1) / 1.5)))),
            ("Интро B", min(1, Double(c.intro) / 16)),
        ]
        let criteria: [(String, Double)] = [
            ("Басы не спорят", good(parts.clash, 8)),
            ("Ровная громкость", good(parts.hole, 4)),
            ("Без перегруза", good(parts.loud, 4)),
            ("Голоса не мешают", good(parts.voice, 4)),
            ("Стиль трека", max(0, min(1, 0.5 + parts.style / 1.5))),
            ("Новизна", good(parts.novelty, 0.8)),
            ("Твой вкус", parts.like),
        ]
        var best = [Double](repeating: -.infinity, count: Recipe.Exit.allCases.count)
        for (r, s) in scored { best[r.exit.rawValue] = max(best[r.exit.rawValue], s) }
        let finite = best.filter { $0.isFinite }
        let lo = finite.min() ?? 0, hi = finite.max() ?? 1
        let outputs = best.enumerated().map { i, s in (exitNames[i], s.isFinite ? 0.08 + 0.92 * (s - lo) / max(0.001, hi - lo) : 0) }
        DJThinking.shared.thought = Thought(inputs: inputs, criteria: criteria, outputs: outputs, chosen: chosen.exit.rawValue, headline: headline)
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

    private static func score(_ r: Recipe, _ c: Ctx, history: [[Int]], _ g: inout SystemRandomNumberGenerator, parts: Parts? = nil) -> Double {
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
        let base = sc

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

        let style = sc - base
        // новизна: недавние переходы не повторяем
        let beforeNovelty = sc
        for (i, h) in history.reversed().enumerated() {
            let same = zip(h, r.signature).filter { $0 == $1 }.count
            sc -= 1.3 * pow(Double(same) / 5, 2) * pow(0.8, Double(i))
            if i == 0 && h.count > 1 && h[1] == r.exit.rawValue { sc -= 0.5 }
        }
        let like = MixBrain.shared.like(r)
        if let parts {
            parts.clash = clash / n; parts.hole = hole / n; parts.loud = loud / n; parts.voice = voice / n
            parts.style = style; parts.novelty = beforeNovelty - sc; parts.like = like
        }
        // вкус слушателя
        sc += 1.4 * (like - 0.5)
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

/// Последнее решение ИИ-композитора — для экрана «Как думает ИИ» (меняется на главном потоке).
final class DJThinking: ObservableObject {
    static let shared = DJThinking()
    @Published var thought: MixComposer.Thought?
}


// MARK: - TransitionNet: переход рисует нейросеть

extension MixComposer {
    static let neuralSamples = 24

    /// Переход, нарисованный TransitionNet: 12 «настроений» → 12 переходов → лучший по «судье» и новизне.
    static func composeNeural(a: TrackAnalysis, b: TrackAnalysis, rateA: Double, ratio: Double,
                              titleA: String, titleB: String, now: Double, start: Double? = nil) -> MixPlan? {
        let T = TransitionNet.T, K = TransitionNet.outputs
        let nA = a.beatBands.count / 3, nB = b.beatBands.count / 3
        guard TransitionNet.isAvailable, nA >= T + 4, nB >= T else { return nil }
        // окно A: за 4 такта до аутро (или сразу со следующей сильной доли), всегда с сильной доли
        var a0: Int
        if let start {
            a0 = Int(((start - a.firstBeat) / a.beat).rounded())
        } else {
            var bar = a.outroStartBar - 4
            if bar + 8 > a.lastSoundBar + 1 { bar = a.lastSoundBar + 1 - 8 }
            bar = max(bar, a.bar(at: now) + 2)
            a0 = bar * 4
        }
        a0 = max(0, min(a0, (nA - T) / 4 * 4))
        let b0 = max(0, min(max(0, b.introEndBar * 4 - 16) / 4 * 4, (nB - T) / 4 * 4))

        let keyDist = TrackAnalysis.keyDistance(a, b)
        let keyFit: Float = switch keyDist { case 0: 1; case 1: 0.85; case 2: 0.5; case nil: 0.6; default: 0.25 }
        let synced = abs(ratio - 1) <= 0.08 && a.confidence >= 0.5 && b.confidence >= 0.5
        let hot = b.dropJump >= 1.5
        let wa = Array(a.beatBands[a0 * 3..<(a0 + T) * 3]), wb = Array(b.beatBands[b0 * 3..<(b0 + T) * 3])
        let tailMean = { (x: [Float], from: Int, to: Int) -> Float in
            var s: Float = 0; for t in from..<to { s += (x[t * 3] + x[t * 3 + 1] + x[t * 3 + 2]) / 3 }; return s / Float(to - from)
        }
        let chill = !hot && (a.bpm * rateA < 100 || (tailMean(wa, T - 8, T) < 0.45 && tailMean(wb, 0, 8) < 0.45))
        let ctx = TransitionNet.Context(a: wa, b: wb, synced: synced ? 1 : 0, keyFit: keyFit, hot: hot ? 1 : 0, chill: chill ? 1 : 0,
                                        tempoDev: Float(min(1, abs(ratio - 1) / 0.08)))

        var cands: [(y: [Float], z: [Float], score: Double)] = []
        let history = TNHistory.shared.items
        for _ in 0..<neuralSamples {
            let z = TransitionNet.randomZ()
            guard let y = TransitionNet.run(ctx, z: z) else { return nil }
            let sig = signature(y)
            var sc = evaluate(y, ctx)
            for (i, h) in history.reversed().enumerated() {
                let d = zip(h, sig).map { abs($0 - $1) }.reduce(0, +) / Float(sig.count)
                sc -= Double(max(0, 1 - d / 0.12)) * 0.4 * pow(0.8, Double(i))
            }
            cands.append((y, z, sc))
        }
        cands.sort { $0.score > $1.score }
        // почти такие же хорошие, но другого стиля, чем последние переходы — в приоритете
        let recent = Set(TNHistory.shared.styles.suffix(2))
        let fresh = cands.filter { $0.score >= cands[0].score - 0.06 && !recent.contains(styleOf($0.y)) }
        let pick = fresh.isEmpty ? cands[Int.random(in: 0..<min(3, cands.count))] : fresh[Int.random(in: 0..<min(3, fresh.count))]
        TNHistory.shared.addStyle(styleOf(pick.y))
        let y = pick.y
        func v(_ t: Int, _ k: Int) -> Float { y[t * K + k] }

        // кривые → дорожки дек (по долям), в конце — B открыт, A смолк
        var s = MixScript(total: Double(T + 4), swap: 0, bEnter: 0)
        let pts = (0...T).map(Double.init)
        func lane(_ k: Int, end: Float, log: Bool = false, _ map: (Float) -> Float) -> MixScript.Lane {
            .init(pts: pts, vals: (0..<T).map { map(v($0, k)) } + [end], log: log)
        }
        s.a.vol = lane(0, end: 0) { $0 }
        s.a.bass = lane(1, end: -26) { -26 * (1 - $0) }
        s.a.mid = lane(2, end: -12) { -12 * (1 - $0) }
        s.a.hp = lane(3, end: 20 * pow(35, v(T - 1, 3)), log: true) { 20 * pow(35, $0) }
        s.a.lp = lane(4, end: 20000 * pow(0.02, v(T - 1, 4)), log: true) { 20000 * pow(0.02, $0) }
        s.a.echo = lane(5, end: 70 * v(T - 1, 5)) { 70 * $0 }
        s.a.reverb = lane(6, end: 85 * v(T - 1, 6)) { 85 * $0 }
        s.a.gain = lane(7, end: -96) { $0 < 0.02 ? -96 : max(-96, 20 * log10($0)) }
        s.b.vol = lane(8, end: 1) { $0 }
        s.b.bass = lane(9, end: 0) { -26 * (1 - $0) }
        s.b.mid = lane(10, end: 0) { -12 * (1 - $0) }
        s.b.hp = lane(11, end: 20, log: true) { 20 * pow(35, $0) }
        s.b.lp = lane(12, end: 20000, log: true) { 20000 * pow(0.02, $0) }
        s.echoBeats = [0.75, 0.5].randomElement()!
        s.echoFeedback = 50
        // смена: где бас B начинает перевешивать бас A
        var swapBeat = T / 2
        for t in 0..<T where v(t, 9) * v(t, 8) > v(t, 1) * v(t, 0) * v(t, 7) { swapBeat = t; break }
        s.swap = Double(max(1, swapBeat))
        if hot && !chill && swapBeat >= 4 {
            let len = Double(min(8, swapBeat))
            if Bool.random() { s.events.append(.synth(.riser, at: s.swap - len, beats: len)) }
            if Bool.random() { s.events.append(.synth(.impact, at: s.swap, beats: 4)) }
        }
        TNHistory.shared.add(signature(y))

        // что нарисовала сеть — словами
        func maxOf(_ k: Int, _ r: Range<Int>) -> Float { r.map { v($0, k) }.max() ?? 0 }
        let tA = "«\(titleA)»", tB = "«\(titleB)»"
        let exit: (String, String) = maxOf(5, 0..<T) > 0.4 ? ("Эхо", "\(tA) улетает в эхо")
            : maxOf(6, 0..<T) > 0.45 ? ("Растворение", "\(tA) растворяется в реверберации")
            : maxOf(4, 0..<T) > 0.45 ? ("Глухой фильтр", "\(tA) глохнет в низкочастотном фильтре")
            : maxOf(3, 0..<T) > 0.45 ? ("Фильтр-уход", "\(tA) уходит в высокочастотный фильтр")
            : ("Плавный микс", "\(tA) плавно гаснет")
        let entry = v(1, 11) > 0.45 ? "\(tB) раскрывается из высокочастотного фильтра"
            : v(1, 12) > 0.45 ? "\(tB) поднимается из-под глухого фильтра"
            : v(2, 8) < 0.2 ? "\(tB) вступает позже, на сильную долю" : "\(tB) входит и набирает громкость"
        let steps = ["Такт 1: \(entry)" + (maxOf(2, 0..<swapBeat) < 0.6 ? ", голос \(tA) отходит назад" : ""),
                     "Доля \(swapBeat + 1): бас переходит к \(tB)", "Дальше: \(exit.1)"]
        let tempoText = abs(ratio - 1) < 0.005 ? "темп совпадает" : synced ? "подгоню темп \(tB) на \(String(format: "%+.1f%%", (ratio - 1) * 100))"
            : "темпы не сводятся — без наложения ритма"
        var m = MixPlan(technique: .composed, aStart: a.firstBeat + Double(a0) * a.beat, bStart: b.firstBeat + Double(b0) * b.beat,
                        overlapBeats: s.swap, tailBeats: s.total - s.swap, synced: synced, riser: false, impact: false, echoTail: 0,
                        headline: "TransitionNet · \(exit.0)",
                        reason: "\(tempoText); нейросеть нарисовала \(neuralSamples) переходов, выбран лучший", steps: steps, variantTitle: "TransitionNet")
        m.script = s

        // для «Как думает ИИ»: входы → настроение → кривые
        var activity = [Double](repeating: 0, count: K)
        let neutral: [Float] = [1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0]
        for k in 0..<K { activity[k] = Double((0..<T).map { abs(v($0, k) - neutral[k]) }.reduce(0, +) / Float(T)) }
        let mx = max(0.001, activity.max() ?? 1)
        DJThinking.shared.thought = Thought(
            inputs: [("Темп", synced ? max(0.15, 1 - abs(ratio - 1) / 0.08) : 0.1), ("Сетка битов", min(a.confidence, b.confidence)),
                     ("Тональность", Double(keyFit)), ("Энергия A", Double(tailMean(wa, T - 8, T))), ("Энергия B", Double(tailMean(wb, 0, 8))),
                     ("Дроп B", Double(max(0, min(1, (b.dropJump - 1) / 1.5)))), ("Интро B", min(1, Double(b.introEndBar) / 16))],
            criteria: pick.z.prefix(7).enumerated().map { ("Настроение \($0.offset + 1)", 1 / (1 + exp(-Double($0.element)))) },
            outputs: (0..<K).map { (TransitionNet.channelNames[$0], 0.06 + 0.94 * activity[$0] / mx) },
            chosen: activity.firstIndex(of: activity.max() ?? 0) ?? 0, headline: m.headline,
            summary: "Нарисовала \(neuralSamples) переходов → \(m.headline)", middleTitle: "Настроение", outputTitle: "Рисует")
        return m
    }

    /// Стиль ухода A: по тому, какие ручки сеть крутит сильнее всего.
    static func styleOf(_ y: [Float]) -> String {
        let T = TransitionNet.T, K = TransitionNet.outputs
        func mx(_ k: Int) -> Float { (0..<T).map { y[$0 * K + k] }.max() ?? 0 }
        if mx(5) > 0.4 { return "echo" }
        if mx(6) > 0.45 { return "reverb" }
        if mx(4) > 0.45 { return "lowpass" }
        if mx(3) > 0.45 { return "highpass" }
        return "fade"
    }

    /// Короткий «отпечаток» перехода — чтобы не повторяться.
    private static func signature(_ y: [Float]) -> [Float] {
        let T = TransitionNet.T, K = TransitionNet.outputs
        var out: [Float] = []
        for k in 0..<K {
            for q in 0..<4 {
                var s: Float = 0
                for t in q * 8..<(q + 1) * 8 where t < T { s += y[t * K + k] }
                out.append(s / 8)
            }
        }
        return out
    }

    /// «Судья» — та же оценка, на которой училась сеть: басы, голоса, провалы и перегруз громкости.
    private static func evaluate(_ y: [Float], _ c: TransitionNet.Context) -> Double {
        let T = TransitionNet.T, K = TransitionNet.outputs
        func g(_ hp: Float, _ lp: Float, _ f: Float) -> Float {
            let hz = 20 * pow(35, hp), lz = 20000 * pow(0.02, lp)
            return 1 / (1 + pow(hz / f, 2)) / (1 + pow(f / lz, 2))
        }
        var clash = 0.0, voice = 0.0, hole = 0.0, over = 0.0, unsync = 0.0, acc: Float = 0
        func sum3(_ x: [Float], _ t: Int) -> Float { x[t * 3] + x[t * 3 + 1] + x[t * 3 + 2] }
        var refA: Float = 0, refB: Float = 0
        for t in 0..<4 { refA += sum3(c.a, t) / 4 }
        for t in T - 6..<T { refB += sum3(c.b, t) / 6 }
        for t in 0..<T {
            let o = t * K
            let gA = y[o] * y[o + 7], gB = y[o + 8]
            let lowA = c.a[t * 3] * gA * y[o + 1] * g(y[o + 3], y[o + 4], 80)
            let midA = c.a[t * 3 + 1] * gA * (0.25 + 0.75 * y[o + 2]) * g(y[o + 3], y[o + 4], 700)
            let hiA = c.a[t * 3 + 2] * gA * g(y[o + 3], y[o + 4], 5000)
            let lowB = c.b[t * 3] * gB * y[o + 9] * g(y[o + 11], y[o + 12], 80)
            let midB = c.b[t * 3 + 1] * gB * (0.25 + 0.75 * y[o + 10]) * g(y[o + 11], y[o + 12], 700)
            let hiB = c.b[t * 3 + 2] * gB * g(y[o + 11], y[o + 12], 5000)
            let wet: Float = 0.7 * y[o + 5] + 0.6 * y[o + 6]
            let aE: Float = sum3(c.a, t) / 3
            acc = acc * 0.72 + y[o] * wet * aE * max(0.3, y[o + 7])
            let totA = lowA + midA + hiA, totB = lowB + midB + hiB
            let total = totA + totB + acc * 0.35
            let target = refA + (refB - refA) * Float(t) / Float(T - 1)
            clash += Double(max(0, min(lowA, lowB) - 0.12)) * 8
            let keyW: Double = 1 + 2 * Double(1 - c.keyFit)
            voice += Double(max(0, min(midA, midB) - 0.25)) * keyW * 3
            let h: Float = max(0, 0.55 * target - total)
            hole += Double(h * h) * 6
            let ov: Float = max(0, total - 1.3 * max(target, 0.3))
            over += Double(ov * ov) * 4
            unsync += Double(min(totA, totB) * (1 - c.synced)) * 6
        }
        return -(clash + voice + hole + over + unsync) / Double(T) + Double.random(in: -0.01...0.01)
    }
}

/// Отпечатки последних переходов TransitionNet — чтобы сеть не повторялась.
final class TNHistory {
    static let shared = TNHistory()
    private let key = "tn.history"
    private(set) var items: [[Float]]
    private(set) var styles: [String]
    private init() {
        items = (UserDefaults.standard.array(forKey: key) as? [[Double]])?.map { $0.map(Float.init) } ?? []
        styles = UserDefaults.standard.stringArray(forKey: key + ".styles") ?? []
    }
    func addStyle(_ s: String) {
        styles.append(s)
        if styles.count > 6 { styles.removeFirst(styles.count - 6) }
        UserDefaults.standard.set(styles, forKey: key + ".styles")
    }
    func add(_ s: [Float]) {
        items.append(s)
        if items.count > 6 { items.removeFirst(items.count - 6) }
        UserDefaults.standard.set(items.map { $0.map(Double.init) }, forKey: key)
    }
}
