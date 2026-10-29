import AVFoundation

/// Идущий переход между треками.
struct Transition {
    let from: Deck
    let to: Deck
    let plan: MixPlan
    let startHost: UInt64          // сильная доля A, с которой начинается переход
    let beatReal: Double           // длительность доли A в реальных секундах
    let rateB: Float
    let beatB: Double              // доля B (сек файла) с учётом ×2 / ×½
    var swapped = false

    var beats: Double { plan.totalBeats }
    func progress(at host: UInt64) -> Double {
        let dt = AVAudioTime.seconds(forHostTime: host) - AVAudioTime.seconds(forHostTime: startHost)
        return dt / beatReal / beats
    }
}

/// Живые значения для экрана DJ-лаборатории.
struct DJSnapshot {
    var plan: MixPlan?
    var progress: Double
    var a: DeckInfo
    var b: DeckInfo?
    var crossfade: Double          // 0 — слышно A, 1 — слышно B

    struct DeckInfo {
        var title: String
        var artist: String
        var cover: URL?
        var bpm: Double?
        var key: String?
        var rate: Double
        var phase: Double?
        var level: Double
        var filter: String?
    }
}

extension Player {
    private var realRate: Double { Double(activeDeck.timePitch.rate * activeDeck.varispeed.rate) }
    var djAIMode: Bool { settings.djMode != "classic" }

    /// Вызывается 30 раз в секунду.
    func djTick() {
        MixBrain.shared.tick()
        if let tr = transition { updateTransition(tr); return }
        applyGlide()
        crossfadeTick()
        let on = settings.djEnabled || demoActive
        if on, !djReady { ensureAnalysis() }
        guard on, let a = activeDeck.analysis, let p = prepared, let b = p.analysis, repeatMode != .one else { return }
        let pos = activeDeck.currentTime
        var mix = plannedMix(a: a, b: b, next: p.song)
        if pos > mix.aStart + 0.5 {   // момент упущен (перемотка, пауза) — пересчитать от текущего места
            plan = nil
            mix = plannedMix(a: a, b: b, next: p.song)
        }
        if pos >= mix.aStart - 0.6 * realRate, pos < a.duration - 1 {
            beginTransition(beats: settings.djBeats)
        }
    }

    /// Без DJ-режима: обычный кроссфейд за `settings.crossfade` секунд до конца.
    private func crossfadeTick() {
        let secs = settings.crossfade
        guard !settings.djEnabled, !demoActive, secs >= 1, repeatMode != .one, let p = prepared,
              let render = activeDeck.player.lastRenderTime, render.isHostTimeValid else { return }
        let a = activeDeck.analysis
        let end = a.map { min($0.lastSound, activeDeck.duration) } ?? activeDeck.duration
        let pos = activeDeck.currentTime
        guard end > secs * 3, pos >= end - secs, pos < end - 0.5 else { return }
        let mix = DJPlanner.crossfade(a: a, duration: activeDeck.duration, seconds: min(secs, end - pos),
                                      bStart: p.analysis.map { max(0, $0.mixIn - 0.05) } ?? 0)
        let from = activeDeck, to = decks[1 - active]
        to.load(song: p.song, file: p.file, analysis: p.analysis, engine: engine)
        prepared = nil
        to.mixer.outputVolume = 0
        to.schedule(from: mix.bStart, at: render.hostTime)
        // для кроссфейда «доля» = секунда, весь переход = secs
        var m = mix
        m.aStart = pos
        transition = Transition(from: from, to: to, plan: m, startHost: render.hostTime, beatReal: 1, rateB: 1, beatB: 1)
    }

    /// План перехода к следующему треку (кэшируется на пару и вариант).
    func plannedMix(a: TrackAnalysis, b: TrackAnalysis, next: Song) -> MixPlan {
        let key = (current?.id ?? "") + ">" + next.id + "#\(demoVariant)#\(settings.djMode)"
        if let plan, plan.key == key { return plan.mix }
        let mix = DJPlanner.plan(a: a, b: b, rateA: realRate, titleA: current?.title ?? "", titleB: next.title,
                                 variant: demoVariant, classic: !djAIMode, beatsSetting: settings.djBeats,
                                 now: activeDeck.currentTime)
        plan = (key, mix)
        return mix
    }

    private func tempoRatio(a: TrackAnalysis, rateA: Double, b: TrackAnalysis) -> (ratio: Double, mult: Double) {
        let bpmA = a.bpm * rateA
        let mult = [1.0, 2, 0.5].min { abs(bpmA / (b.bpm * $0) - 1) < abs(bpmA / (b.bpm * $1) - 1) }!
        return (bpmA / (b.bpm * mult), mult)
    }

    func beginTransition(beats: Int) {
        ensureGraph()
        guard let p = prepared, let aB = p.analysis, let aA = activeDeck.analysis,
              let render = activeDeck.player.lastRenderTime, render.isHostTimeValid else { return }
        var mix = plannedMix(a: aA, b: aB, next: p.song)
        let from = activeDeck
        let to = decks[1 - active]
        let posA = from.currentTime
        // ручное «следующий»: переход сразу, со следующей сильной доли
        if mix.aStart > posA + 1.5, mix.technique == .composed {
            mix = DJPlanner.plan(a: aA, b: aB, rateA: realRate, titleA: current?.title ?? "", titleB: p.song.title,
                                 variant: demoVariant, classic: false, beatsSetting: settings.djBeats, now: posA,
                                 start: aA.downbeat(atOrAfter: posA + 0.35))
        } else if mix.aStart > posA + 1.5 {
            mix.aStart = aA.downbeat(atOrAfter: posA + 0.35)
            if mix.overlapping {
                mix.overlapBeats = min(mix.overlapBeats, 16); mix.tailBeats = min(mix.tailBeats, 8)
                // дроп B — ровно на смену басов
                if aB.introEndBar > 0 { mix.bStart = aB.time(ofBar: max(0, aB.introEndBar - Int(mix.overlapBeats / 4))) }
            }
        }
        to.load(song: p.song, file: p.file, analysis: aB, engine: engine)
        prepared = nil
        plan = nil

        let rateA = realRate
        let (ratio, mult) = tempoRatio(a: aA, rateA: rateA, b: aB)
        // у B своя базовая скорость (Sped up / Slowed) — темп подгоняем поверх неё
        let rateB = Float(mix.synced ? ratio / Double(to.baseVarispeed) : 1)
        let aStart = max(mix.aStart, aA.downbeat(atOrAfter: posA + 0.1))
        let beatReal = aA.beat / rateA
        let startHost = render.hostTime + AVAudioTime.hostTime(forSeconds: (aStart - posA) / rateA)
        func host(_ frac: Double) -> UInt64 { startHost + AVAudioTime.hostTime(forSeconds: max(0, beatReal * mix.totalBeats * frac)) }

        to.timePitch.rate = rateB
        if let sc = mix.script {
            applyLanes(sc.b, to: to, at: 0, script: sc, beatReal: beatReal)
            to.schedule(from: mix.bStart, at: host(sc.bEnter / sc.total))
            if let r = mix.recipe { MixBrain.shared.began(r); lastRecipe = r }
        } else {
        switch mix.technique {
        case .bassSwap:
            to.mixer.outputVolume = 0; to.bass.gain = -26
            to.schedule(from: mix.bStart, at: startHost)
        case .filterSwap:
            to.mixer.outputVolume = 0; to.bass.gain = -26
            to.highPass.bypass = false; to.highPass.frequency = 1200
            to.schedule(from: mix.bStart, at: startHost)
        case .echoOut, .backspin, .fade, .composed:
            to.mixer.outputVolume = 1
            to.schedule(from: mix.bStart, at: host(mix.swapAt))
        }
        }

        transition = Transition(from: from, to: to, plan: mix, startHost: startHost, beatReal: beatReal,
                                rateB: rateB, beatB: aB.beat / mult)
        glide = nil
        djStatus = mix.headline
        djDecision = (djAIMode ? "ИИ: " : "Классика: ") + mix.reason
        scheduleFX(mix, from: from, aA: aA, aStart: aStart, host: host, beatReal: beatReal)
    }

    private func scheduleFX(_ m: MixPlan, from: Deck, aA: TrackAnalysis, aStart: Double, host: (Double) -> UInt64, beatReal: Double) {
        let gain = Float(settings.djFX)
        let swapHost = host(m.swapAt)
        func at(_ h: UInt64) -> AVAudioTime { AVAudioTime(hostTime: h) }

        if let sc = m.script {
            if !fxPlayer.isPlaying { fxPlayer.play() }
            if !fxTrack.isPlaying { fxTrack.play() }
            let trim = pow(10, from.trim.globalGain / 20)
            func hostAt(_ beat: Double) -> AVAudioTime { at(host(beat / sc.total)) }
            func slice(_ beat: Double, _ seconds: Double) -> AVAudioPCMBuffer? {
                from.file.flatMap { DJBuffers.slice(of: $0.url, at: aStart + aA.beat * beat, seconds: seconds) }
            }
            for e in sc.events {
                switch e {
                case .synth(let kind, let x, let beats):
                    guard gain > 0.01 else { continue }
                    let buf: AVAudioPCMBuffer = switch kind {
                    case .riser: FXSynth.scaled(FXSynth.riser(seconds: beatReal * beats), gain: 0.4 * gain)
                    case .snareRoll: FXSynth.scaled(FXSynth.snareRoll(seconds: beatReal * beats, beat: beatReal), gain: 0.5 * gain)
                    case .impact: FXSynth.scaled(FXSynth.impact(), gain: 0.6 * gain)
                    case .crash: FXSynth.scaled(FXSynth.crash(), gain: 0.45 * gain)
                    case .downlifter: FXSynth.scaled(FXSynth.downlifter(seconds: beatReal * beats), gain: 0.45 * gain)
                    case .subDrop: FXSynth.scaled(FXSynth.subDrop(), gain: 0.55 * gain)
                    }
                    fxPlayer.scheduleBuffer(buf, at: hostAt(max(0, x)))
                case .roll(let x, let beats):
                    if let src = slice(x, aA.beat), let buf = DJBuffers.roll(from: src, beat: beatReal, beats: beats, gain: trim) {
                        fxTrack.scheduleBuffer(buf, at: hostAt(x))
                    }
                case .gate(let x, let beats):
                    if let src = slice(x, aA.beat * beats), let buf = DJBuffers.gate(src, beat: beatReal, gain: trim) {
                        fxTrack.scheduleBuffer(buf, at: hostAt(x))
                    }
                case .brake(let x, let beats):
                    if let src = slice(x, beatReal * beats), let buf = DJBuffers.tapeStop(from: src, seconds: beatReal * beats, gain: trim) {
                        fxTrack.scheduleBuffer(buf, at: hostAt(x))
                    }
                case .spin(let x, let beats):
                    if let src = slice(x - 1.2 / aA.beat, 1.2), let buf = DJBuffers.backspin(from: src, seconds: beatReal * beats, gain: trim) {
                        fxTrack.scheduleBuffer(buf, at: hostAt(x))
                    }
                }
            }
            return
        }

        if m.technique == .backspin {
            let spinBeats = 4.0
            let spinFromBeat = m.overlapBeats - spinBeats
            if let url = from.file?.url,
               let src = DJBuffers.slice(of: url, at: aStart + aA.beat * spinFromBeat - 1.2, seconds: 1.2),
               let spin = DJBuffers.backspin(from: src, seconds: beatReal * spinBeats, gain: 1.0) {
                fxPlayer.scheduleBuffer(spin, at: at(host(spinFromBeat / m.totalBeats)))
            }
        }
        guard gain > 0.01 else { return }
        if m.riser {
            let len = beatReal * (m.overlapping ? 16 : 8)
            fxPlayer.scheduleBuffer(FXSynth.scaled(FXSynth.riser(seconds: len), gain: 0.4 * gain), at: at(swapHost - AVAudioTime.hostTime(forSeconds: len)))
        }
        if m.impact {
            fxPlayer.scheduleBuffer(FXSynth.scaled(FXSynth.impact(), gain: 0.6 * gain), at: at(swapHost))
        }
    }

    // MARK: Автоматизация

    private func updateTransition(_ tr: Transition) {
        let p = tr.progress(at: mach_absolute_time())
        let a = tr.from, b = tr.to, m = tr.plan
        let S = m.swapAt
        let w = 1 / tr.beats
        func ramp(_ x0: Double, _ x1: Double) -> Double { max(0, min(1, (p - x0) / max(0.0001, x1 - x0))) }
        func fadeDB(_ k: Double) -> Float { Float(max(-96, 20 * log10(max(0.00001, cos(k * .pi / 2))))) }

        if let sc = m.script {
            let x = p * tr.beats
            applyLanes(sc.a, to: a, at: x, script: sc, beatReal: tr.beatReal)
            applyLanes(sc.b, to: b, at: x, script: sc, beatReal: tr.beatReal)
        } else {
        switch m.technique {
        case .bassSwap:
            // B: за первые 4 такта плавно поднимается (без баса); на смене — бас B, A без баса
            b.mixer.outputVolume = Float(p <= 0 ? 0 : sin(ramp(0, min(S, 16 * w)) * .pi / 2))
            b.bass.gain = Float(-26 + 26 * ramp(S, S + w))
            a.bass.gain = Float(-26 * ramp(S, S + w))
            // A после смены: фильтр вверх, лёгкое эхо, затухание до конца хвоста
            if p > S { a.highPass.bypass = false; a.highPass.frequency = Float(20 * pow(30, ramp(S, 1))) }
            a.eq.globalGain = p < S ? 0 : fadeDB(ramp(S, 1))
            if m.echoTail > 0, p > S + 0.5 * (1 - S) {
                a.delay.delayTime = min(2, tr.beatReal * 0.75)
                a.delay.wetDryMix = 100 * m.echoTail * Float(ramp(S + 0.5 * (1 - S), 1))
            }
        case .filterSwap:
            b.mixer.outputVolume = Float(ramp(0, min(S, 8 * w)))
            b.highPass.frequency = Float(1200 * pow(20.0 / 1200, ramp(0, S)))
            if p >= S { b.highPass.bypass = true }
            b.bass.gain = Float(-26 + 26 * ramp(S, S + w))
            a.bass.gain = Float(-26 * ramp(S, S + w))
            if p > S * 0.4 { a.lowPass.bypass = false; a.lowPass.frequency = Float(20000 * pow(500.0 / 20000, ramp(S * 0.4, S))) }
            a.eq.globalGain = p < S ? 0 : fadeDB(ramp(S, 1))
        case .echoOut:
            // A два такта уходит в фильтр и эхо, затем замолкает — остаётся хвост эха
            a.highPass.bypass = false
            a.highPass.frequency = Float(20 * pow(60, ramp(0, S)))
            a.delay.delayTime = min(2, tr.beatReal * 0.75)
            a.delay.feedback = 55
            a.delay.wetDryMix = 100 * m.echoTail * Float(ramp(0.2 * S, S))
            a.eq.globalGain = Float(-96 * ramp(S - 0.5 * w, S + 0.5 * w))
        case .backspin:
            if p >= S - 4 * w { a.eq.globalGain = -96 }
        case .fade:
            let k = max(0, min(1, p))
            a.mixer.outputVolume = Float(cos(k * .pi / 2))
            b.mixer.outputVolume = Float(sin(k * .pi / 2))
        case .composed:
            break
        }
        }

        // фаза B подтягивается к A, пока оба играют вместе
        if m.synced, m.overlapping, p > 0, p < S + 2 * w, let aA = a.analysis, let aB = b.analysis {
            let phA = aA.beatPhase(a.currentTime)
            let x = (b.currentTime - aB.firstBeat) / tr.beatB
            var diff = phA - (x - x.rounded(.down))
            if diff > 0.5 { diff -= 1 } else if diff < -0.5 { diff += 1 }
            b.timePitch.rate = tr.rateB * Float(1 + max(-0.004, min(0.004, diff * 0.03)))
        }

        if p >= S, !tr.swapped {
            reportWaveEnd(skipped: false)
            transition?.swapped = true
            active = decks.firstIndex { $0 === b } ?? active
            if let n = queue.firstIndex(where: { $0.id == b.song?.id }), n > index { index = n } else { index = min(index + 1, queue.count - 1) }
            duration = b.duration
            nowPlaying.update()
            if isWave, let s = current { Wave.shared.started(s) }
        }
        if p >= 1 { completeTransition(tr) }
    }

    /// Значения кривых сценария в доле `x` — на деку.
    private func applyLanes(_ L: MixScript.DeckLanes, to d: Deck, at x: Double, script: MixScript, beatReal: Double) {
        d.mixer.outputVolume = max(0, min(1, L.vol.at(x)))
        d.eq.globalGain = max(-96, L.gain.at(x))
        d.bass.gain = L.bass.at(x)
        d.mid.gain = L.mid.at(x)
        let hp = L.hp.at(x)
        d.highPass.bypass = hp <= 21
        d.highPass.frequency = max(20, hp)
        let lp = L.lp.at(x)
        d.lowPass.bypass = lp >= 19500
        d.lowPass.frequency = min(20000, lp)
        let e = L.echo.at(x)
        if e > 0.5 {
            d.delay.delayTime = min(2, beatReal * script.echoBeats)
            d.delay.feedback = script.echoFeedback
        }
        d.delay.wetDryMix = e
        d.reverb.wetDryMix = max(d.baseReverb, L.reverb.at(x))
    }

    private func completeTransition(_ tr: Transition) {
        if let r = tr.plan.recipe { MixBrain.shared.finished(r) }
        tr.from.stop()
        tr.from.resetFX()
        tr.from.timePitch.rate = 1
        tr.to.resetFX()
        tr.to.timePitch.rate = tr.rateB
        tr.from.delay.feedback = 45
        transition = nil
        djStatus = nil
        if demoActive { demoActive = false }
        if settings.djTempoGlide, abs(tr.rateB - 1) > 0.001, let aB = tr.to.analysis {
            glide = ((1 - tr.rateB) / Float(32 * aB.beat), Date())
        }
        prepareNext()
    }

    func applyGlide() {
        guard let g = glide else { return }
        let now = Date()
        let dt = Float(now.timeIntervalSince(g.last))
        let r = activeDeck.timePitch.rate
        var nr = r + g.perSecond * dt
        if (g.perSecond > 0 && nr >= 1) || (g.perSecond < 0 && nr <= 1) { nr = 1; glide = nil } else { glide = (g.perSecond, now) }
        activeDeck.timePitch.rate = nr
    }

    /// Мгновенно завершить переход (пауза, перемотка, выбор другого трека).
    func finishTransitionNow() {
        guard let tr = transition else { return }
        fxPlayer.stop(); fxPlayer.play()
        fxTrack.stop(); fxTrack.play()
        if !tr.swapped {
            tr.to.unload()
            tr.from.resetFX()
        } else {
            tr.from.stop(); tr.from.resetFX(); tr.from.timePitch.rate = 1
            tr.to.resetFX()
        }
        tr.from.delay.feedback = 45
        transition = nil
        djStatus = nil
        prepareNext()
    }

    // MARK: Снимок для DJ-лаборатории

    func djSnapshot() -> DJSnapshot {
        func info(_ d: Deck, level: Double) -> DJSnapshot.DeckInfo {
            let filter: String? = !d.lowPass.bypass ? "НЧ-фильтр \(Int(d.lowPass.frequency)) Гц"
                : !d.highPass.bypass && d.highPass.frequency > 30 ? "ВЧ-фильтр \(Int(d.highPass.frequency)) Гц"
                : d.delay.wetDryMix > 1 ? "Эхо \(Int(d.delay.wetDryMix))%"
                : d.bass.gain < -3 ? "Бас убран" : nil
            return .init(title: d.song?.title ?? "—", artist: d.song?.artist ?? "", cover: d.song?.coverURL(200),
                         bpm: d.analysis.map { $0.bpm * Double(d.timePitch.rate * d.varispeed.rate) },
                         key: d.analysis?.camelot,
                         rate: Double(d.timePitch.rate * d.varispeed.rate),
                         phase: d.analysis.map { $0.beatPhase(d.currentTime) }, level: level, filter: filter)
        }
        if let tr = transition {
            let p = max(0, tr.progress(at: mach_absolute_time()))
            let aLevel = Double(tr.from.mixer.outputVolume) * pow(10, Double(tr.from.eq.globalGain) / 20)
            let bLevel = Double(tr.to.mixer.outputVolume) * (tr.to.player.isPlaying && (tr.plan.overlapping || p >= tr.plan.swapAt) ? 1 : 0)
            let cf = bLevel / max(0.0001, aLevel + bLevel)
            return DJSnapshot(plan: tr.plan, progress: min(1, p),
                              a: info(tr.from, level: aLevel), b: info(tr.to, level: bLevel), crossfade: cf)
        }
        var next: DJSnapshot.DeckInfo?
        var planned: MixPlan?
        if let pr = prepared {
            next = .init(title: pr.song.title, artist: pr.song.artist, cover: pr.song.coverURL(200), bpm: pr.analysis?.bpm,
                         key: pr.analysis?.camelot, rate: 1, phase: nil, level: 0, filter: nil)
            if let a = activeDeck.analysis, let b = pr.analysis { planned = plannedMix(a: a, b: b, next: pr.song) }
        }
        return DJSnapshot(plan: planned, progress: 0, a: info(activeDeck, level: isPlaying ? 1 : 0), b: next, crossfade: 0)
    }
}
