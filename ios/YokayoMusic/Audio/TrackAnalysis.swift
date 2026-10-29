import Foundation
import AVFoundation
import Accelerate

/// Результат анализа трека для DJ-режима.
struct TrackAnalysis: Codable {
    var bpm: Double
    var firstBeat: Double          // секунда первой сильной доли (начало такта 0)
    var duration: Double
    var energy: [Float]            // громкость по секундам, 0…1
    var mixIn: Double              // где начинается музыка (сильная доля)
    var lastSound: Double          // где кончается музыка (без тишины)
    // v2
    var confidence: Double = 0.5   // насколько надёжна сетка битов, 0…1
    var key: Int? = nil            // 0…11 мажор (C…B), 12…23 минор
    var barEnergy: [Float] = []    // громкость по тактам
    var barLow: [Float] = []       // бас по тактам
    var introEndBar: Int = 0       // такт, где начинается основная часть (дроп)
    var outroStartBar: Int = 0     // такт, где начинается аутро
    var outroFound: Bool = false   // аутро настоящее (энергия падает), а не «последние 8 тактов»

    var beat: Double { 60 / bpm }
    var bar: Double { beat * 4 }
    var barCount: Int { max(0, Int((duration - firstBeat) / bar)) }
    func time(ofBar n: Int) -> Double { firstBeat + Double(n) * bar }
    func bar(at t: Double) -> Int { max(0, Int(((t - firstBeat) / bar).rounded(.down))) }
    var lastSoundBar: Int { bar(at: lastSound) }

    /// Ближайшая сильная доля такта не раньше `t`.
    func downbeat(atOrAfter t: Double) -> Double {
        let n = ((t - firstBeat) / bar).rounded(.up)
        return firstBeat + max(0, n) * bar
    }

    func downbeat(atOrBefore t: Double) -> Double {
        let n = ((t - firstBeat) / bar).rounded(.down)
        return firstBeat + max(0, n) * bar
    }

    /// Фаза внутри доли, 0…1.
    func beatPhase(_ t: Double) -> Double {
        let x = (t - firstBeat) / beat
        return x - x.rounded(.down)
    }

    /// Где начинать уход из трека, чтобы переход длиной `beats` долей закончился до конца музыки.
    func mixOut(beats: Int, phrase: Bool = false) -> Double {
        let length = Double(beats) * beat
        let target = max(duration * 0.5, lastSound - length)
        if phrase {
            let p = bar * 8
            let n = ((target - firstBeat) / p).rounded(.down)
            let start = firstBeat + max(0, n) * p
            if target - start <= bar * 4, start > duration * 0.4 { return start }
        }
        return downbeat(atOrBefore: target)
    }

    /// Тональность в нотации Camelot (8A, 11B…) — как у диджеев.
    var camelot: String? {
        guard let key else { return nil }
        // мажор: C=8B, G=9B …; минор: Am=8A, Em=9A …
        let majorCamelot = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
        let minorCamelot = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
        return key < 12 ? "\(majorCamelot[key])B" : "\(minorCamelot[key - 12])A"
    }

    /// Насколько гармонично звучат вместе (0 — та же, 1 — соседи по кругу, больше — конфликт).
    static func keyDistance(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Int? {
        guard let ca = a.camelot, let cb = b.camelot,
              let na = Int(ca.dropLast()), let nb = Int(cb.dropLast()) else { return nil }
        let d = min(abs(na - nb), 12 - abs(na - nb))
        return d + (ca.last == cb.last ? 0 : (d == 0 ? 1 : 2))
    }

    /// Средняя громкость тактов [from, to).
    func meanBarEnergy(_ from: Int, _ to: Int) -> Float {
        let a = max(0, from), b = min(barEnergy.count, to)
        guard b > a else { return 0 }
        return barEnergy[a..<b].reduce(0, +) / Float(b - a)
    }

    /// Во сколько раз дроп громче интро.
    var dropJump: Float {
        guard introEndBar > 0 else { return 1 }
        let before = meanBarEnergy(introEndBar - 4, introEndBar), after = meanBarEnergy(introEndBar, introEndBar + 4)
        return before > 0.01 ? after / before : 2
    }
}

enum BeatAnalyzer {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Analysis3", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func cached(_ id: String) -> TrackAnalysis? {
        let url = dir.appendingPathComponent(AudioFiles.safeName(id) + ".json")
        return try? JSONDecoder().decode(TrackAnalysis.self, from: Data(contentsOf: url))
    }

    static func analyze(id: String, file url: URL) async -> TrackAnalysis? {
        if let c = cached(id) { return c }
        let result = await Task.detached(priority: .background) { () -> TrackAnalysis? in
            try? compute(url)
        }.value
        if let result {
            try? JSONEncoder().encode(result).write(to: dir.appendingPathComponent(AudioFiles.safeName(id) + ".json"))
        }
        return result
    }

    // MARK: - Анализ

    private static let sr: Double = 11025
    private static let fftN = 1024
    private static let hop = 128

    @_optimize(speed)
    static func compute(_ url: URL) throws -> TrackAnalysis {
        let mono = try readMono(url)
        let duration = Double(mono.count) / sr
        let fps = sr / Double(hop)

        // 1. Спектр по кадрам: поток (атаки), бас, громкость, хрома (ноты)
        let spec = spectralFeatures(mono)
        let frames = spec.flux.count
        guard frames > 400 else { throw URLError(.cannotDecodeContentData) }

        // 2. Сетка битов: своя нейросеть BeatNet, если её нет — старый спектральный метод
        let onset = normalize(spec.flux)
        let lowOnset = normalize(spec.lowFlux)
        let bpm: Double, confidence: Double
        let firstBeat: Double
        if let out = BeatNet.run(mono: mono), let g = BeatNet.grid(out) {
            bpm = g.bpm; firstBeat = g.firstBeat; confidence = g.confidence
        } else {
            (bpm, firstBeat, confidence) = classicGrid(onset: onset, lowOnset: lowOnset, frames: frames, fps: fps)
        }
        let beat = 60 / bpm
        let bar = beat * 4

        // 5. Громкость по секундам и тактам
        let perSec = Int(fps)
        var energy: [Float] = stride(from: 0, to: frames, by: perSec).map { i in
            let s = spec.rms[i..<min(frames, i + perSec)]
            return s.reduce(0, +) / Float(s.count)
        }
        let peak = energy.max() ?? 1
        if peak > 0 { energy = energy.map { $0 / peak } }
        let nBars = max(1, Int((duration - firstBeat) / bar))
        func barMean(_ x: [Float], _ k: Int) -> Float {
            let a = Int((firstBeat + Double(k) * bar) * fps), b = min(x.count, Int((firstBeat + Double(k + 1) * bar) * fps))
            guard b > a, a >= 0 else { return 0 }
            return x[a..<b].reduce(0, +) / Float(b - a)
        }
        var barEnergy = (0..<nBars).map { barMean(spec.rms, $0) }
        var barLow = (0..<nBars).map { barMean(spec.lowRMS, $0) }
        let bPeak = barEnergy.max() ?? 1, lPeak = barLow.max() ?? 1
        barEnergy = barEnergy.map { $0 / max(0.0001, bPeak) }
        barLow = barLow.map { $0 / max(0.0001, lPeak) }

        // 6. Начало и конец музыки
        let sorted = energy.sorted()
        let median = sorted[sorted.count / 2]
        let firstSound = Double(energy.firstIndex { $0 > median * 0.35 } ?? 0)
        let lastSound = min(duration, Double((energy.lastIndex { $0 > median * 0.35 } ?? energy.count - 1) + 1))

        // 7. Структура: интро → дроп, аутро. Ищем на границах фраз (по 8, затем по 4 такта).
        let body = { () -> Float in
            let s = barEnergy[(nBars / 5)..<max(nBars / 5 + 1, nBars * 4 / 5)].sorted()
            return s[s.count / 2]
        }()
        func mean(_ a: Int, _ b: Int, _ x: [Float]) -> Float {
            let lo = max(0, a), hi = min(x.count, b)
            return hi > lo ? x[lo..<hi].reduce(0, +) / Float(hi - lo) : 0
        }
        var introEnd = 0
        for step in [8, 4] where introEnd == 0 {
            for k in stride(from: step, through: min(64, nBars / 2), by: step) {
                let before = mean(k - step, k, barEnergy), after = mean(k, k + step, barEnergy)
                let lowBefore = mean(k - step, k, barLow), lowAfter = mean(k, k + step, barLow)
                if after >= body * 0.85 && (before < body * 0.75 || lowAfter > lowBefore * 1.4) { introEnd = k; break }
            }
        }
        let lastBar = Int((lastSound - firstBeat) / bar)
        var outroStart = 0
        for step in [8, 4] where outroStart == 0 {
            var k = (lastBar / step) * step
            // аутро — только в конце песни (последние ~24 такта), а не брейкдаун в середине
            while k > max(nBars * 2 / 3, lastBar - 24) {
                let before = mean(k - step, k, barEnergy), after = mean(k, min(lastBar, k + step), barEnergy)
                let lowBefore = mean(k - step, k, barLow), lowAfter = mean(k, min(lastBar, k + step), barLow)
                if before >= body * 0.8 && (after < body * 0.7 || lowAfter < lowBefore * 0.6) { outroStart = k; break }
                k -= step
            }
        }
        let outroFound = outroStart > 0
        if outroStart == 0 { outroStart = max(nBars * 2 / 3, ((lastBar - 8) / 4) * 4) }

        // 8. Тональность: хрома с высоким разрешением × профили Крумхансла
        let key = detectKey(chroma(mono))

        var a = TrackAnalysis(bpm: bpm, firstBeat: firstBeat, duration: duration, energy: energy,
                              mixIn: 0, lastSound: lastSound)
        a.confidence = confidence
        a.key = key
        a.barEnergy = barEnergy
        a.barLow = barLow
        a.introEndBar = introEnd
        a.outroStartBar = outroStart
        a.outroFound = outroFound
        let mixIn = a.downbeat(atOrAfter: max(0, firstSound - 0.05))
        a.mixIn = mixIn < duration * 0.25 ? mixIn : a.firstBeat
        return a
    }

    /// Старый способ: автокорреляция и гребёнка по спектральному потоку.
    private static func classicGrid(onset: [Float], lowOnset: [Float], frames: Int, fps: Double) -> (Double, Double, Double) {
        let comb = zip(onset, lowOnset).map { $0 + 0.8 * $1 }
        var bpm = tempo(comb, fps: fps)

        // 3. Уточнение темпа и фазы гребёнкой; уверенность = насколько пик выше среднего
        var best: (bpm: Double, phase: Double, score: Float) = (bpm, 0, -1)
        var scores: [Float] = []
        for step in -60...60 {
            let cand = bpm + Double(step) * 0.025
            let period = 60 * fps / cand
            var local: [Float] = []
            for ph in stride(from: 0.0, to: period, by: 0.5) {
                var sum: Float = 0, n: Float = 0
                var t = ph
                while t < Double(frames - 1) {
                    let i = Int(t), f = Float(t - Double(i))
                    sum += comb[i] * (1 - f) + comb[i + 1] * f
                    n += 1
                    t += period
                }
                let s = sum / max(1, n)
                local.append(s)
                if s > best.score { best = (cand, ph, s) }
            }
            if step == 0 { scores = local }
        }
        // продюсеры почти всегда ставят целый BPM: берём его, если гребёнка не хуже
        func combScore(_ cand: Double) -> (Float, Double) {
            let period = 60 * fps / cand
            var bestS: Float = -1, bestPh = 0.0
            for ph in stride(from: 0.0, to: period, by: 0.5) {
                var sum: Float = 0, n: Float = 0
                var t = ph
                while t < Double(frames - 1) {
                    let i = Int(t), f = Float(t - Double(i))
                    sum += comb[i] * (1 - f) + comb[i + 1] * f; n += 1; t += period
                }
                if sum / max(1, n) > bestS { bestS = sum / max(1, n); bestPh = ph }
            }
            return (bestS, bestPh)
        }
        let integer = best.bpm.rounded()
        if abs(integer - best.bpm) < 0.6 {
            let (s, ph) = combScore(integer)
            if s >= best.score * 0.97 { best = (integer, ph, s) }
        }
        bpm = (best.bpm * 100).rounded() / 100
        let meanScore = scores.reduce(0, +) / Float(max(1, scores.count))
        let maxScore = scores.max() ?? 1
        let confidence = Double(max(0, min(1, (maxScore - meanScore) / max(0.0001, maxScore) * 1.6)))
        let beat = 60 / bpm
        var firstBeat = best.phase / fps

        // 4. Сильная доля: где в среднем больше бочки
        var bestShift = 0, bestLow: Float = -1
        for shift in 0..<4 {
            var sum: Float = 0
            var t = firstBeat + Double(shift) * beat
            while Int(t * fps) < frames { sum += lowOnset[Int(t * fps)]; t += beat * 4 }
            if sum > bestLow { bestLow = sum; bestShift = shift }
        }
        firstBeat += Double(bestShift) * beat
        return (bpm, firstBeat, confidence)
    }

    // MARK: Чтение

    private static func readMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fileSR = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: file.processingFormat, to: out) else { throw URLError(.cannotDecodeContentData) }
        _ = channels
        conv.downmix = true
        let chunk: AVAudioFrameCount = 1 << 16
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { throw URLError(.cannotDecodeContentData) }
        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) * sr / fileSR) + 1024)
        let outCap = AVAudioFrameCount(Double(chunk) * sr / fileSR) + 256
        var done = false
        while !done {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: outCap) else { break }
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                do {
                    try file.read(into: inBuf, frameCount: chunk)
                } catch { st.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { st.pointee = .endOfStream; return nil }
                st.pointee = .haveData
                return inBuf
            }
            if outBuf.frameLength > 0, let d = outBuf.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: d, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error || err != nil { done = true }
        }
        return result
    }

    // MARK: Спектр

    private struct Spec { var flux: [Float]; var lowFlux: [Float]; var rms: [Float]; var lowRMS: [Float]; var chroma: [Float] }

    private static func spectralFeatures(_ x: [Float]) -> Spec {
        let n = fftN, half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return Spec(flux: [], lowFlux: [], rms: [], lowRMS: [], chroma: []) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let frames = max(0, (x.count - n) / hop)
        var flux = [Float](repeating: 0, count: frames), lowFlux = flux, rms = flux, lowRMS = flux
        var chroma = [Float](repeating: 0, count: 12)
        var prev = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        let binHz = Float(sr) / Float(n)
        let lowBins = Int(150 / binHz)
        // номер ноты для каждого бина (80 Гц … 2.5 кГц)
        let noteOfBin: [Int] = (0..<half).map { k in
            let f = Float(k) * binHz
            guard f >= 80, f <= 2500 else { return -1 }
            let midi = 69 + 12 * log2(f / 440)
            return (Int(midi.rounded()) % 12 + 12) % 12
        }
        x.withUnsafeBufferPointer { xp in
            for f in 0..<frames {
                vDSP_vmul(xp.baseAddress! + f * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                    }
                }
                var fl: Float = 0, lfl: Float = 0, e: Float = 0, le: Float = 0
                for k in 1..<half {
                    let m = log1p(mag[k] * 10)
                    let d = m - prev[k]
                    if d > 0 { fl += d; if k <= lowBins { lfl += d } }
                    prev[k] = m
                    let p = mag[k] * mag[k]
                    e += p
                    if k <= lowBins { le += p }
                    let note = noteOfBin[k]
                    if note >= 0 { chroma[note] += mag[k] }
                }
                flux[f] = fl; lowFlux[f] = lfl
                rms[f] = sqrt(e / Float(half)); lowRMS[f] = sqrt(le / Float(max(1, lowBins)))
            }
        }
        return Spec(flux: flux, lowFlux: lowFlux, rms: rms, lowRMS: lowRMS, chroma: chroma)
    }

    /// Хрома (12 нот) по FFT 4096 — достаточно точно для нот от 65 Гц.
    private static func chroma(_ x: [Float]) -> [Float] {
        let n = 4096, half = n / 2
        let log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = Float(sr) / Float(n)
        let noteOfBin: [Int] = (0..<half).map { k in
            let f = Float(k) * binHz
            guard f >= 65, f <= 2000 else { return -1 }
            let midi = 69 + 12 * log2(f / 440)
            // только бины близко к ноте (меньше «размазывания»)
            guard abs(midi - midi.rounded()) < 0.3 else { return -1 }
            return (Int(midi.rounded()) % 12 + 12) % 12
        }
        var total = [Float](repeating: 0, count: 12)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half), mag = [Float](repeating: 0, count: half)
        let step = n
        var pos = 0
        x.withUnsafeBufferPointer { xp in
            while pos + n < x.count {
                vDSP_vmul(xp.baseAddress! + pos, 1, window, 1, &frame, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                    }
                }
                var c = [Float](repeating: 0, count: 12)
                for k in 1..<half where noteOfBin[k] >= 0 { c[noteOfBin[k]] += log1p(mag[k]) }
                let m = c.reduce(0, +) / 12
                let sd = sqrt(c.map { ($0 - m) * ($0 - m) }.reduce(0, +) / 12)
                if sd > 0 { for i in 0..<12 { total[i] += max(0, (c[i] - m) / sd) } }   // «отбеливание» кадра
                pos += step
            }
        }
        return total
    }

    /// Убрать медленный тренд и привести к 0…1.
    private static func normalize(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        let w = 32
        var out = [Float](repeating: 0, count: x.count)
        var acc: Float = 0
        for i in 0..<x.count {
            acc += x[i]
            if i >= w { acc -= x[i - w] }
            let localMean = acc / Float(min(i + 1, w))
            out[i] = max(0, x[i] - localMean)
        }
        let m = out.max() ?? 1
        return m > 0 ? out.map { $0 / m } : out
    }

    /// Темп по автокорреляции потока (70–180 BPM, предпочтение середине).
    private static func tempo(_ o: [Float], fps: Double) -> Double {
        let minLag = Int((60 / 180.0 * fps).rounded(.down)), maxLag = Int((60 / 68.0 * fps).rounded(.up))
        let n = o.count
        var ac = [Float](repeating: 0, count: maxLag + 2)
        o.withUnsafeBufferPointer { p in
            for lag in minLag...maxLag + 1 where lag < n {
                var r: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &r, vDSP_Length(n - lag))
                ac[lag] = r / Float(n - lag)
            }
        }
        // гармоники усиливают настоящий темп
        var bestLag = Double(minLag), best: Float = -1
        for lag in minLag...maxLag {
            var s = ac[lag]
            if lag * 2 < ac.count { s += 0.5 * ac[lag * 2] }
            let bpm = 60 * fps / Double(lag)
            let prior = Float(exp(-pow(log2(bpm / 122), 2) / (2 * 0.6 * 0.6)))
            s *= 0.55 + 0.45 * prior
            if s > best {
                best = s
                let l = ac[max(minLag, lag - 1)], c = ac[lag], r = ac[lag + 1]
                let den = l - 2 * c + r
                bestLag = Double(lag) + (den != 0 ? Double(max(-0.5, min(0.5, 0.5 * (l - r) / den))) : 0)
            }
        }
        var bpm = 60 * fps / bestLag
        while bpm < 80 { bpm *= 2 }
        while bpm > 175 { bpm /= 2 }
        return bpm
    }

    /// Тональность по профилям Крумхансла.
    private static func detectKey(_ chroma: [Float]) -> Int? {
        let total = chroma.reduce(0, +)
        guard total > 0 else { return nil }
        let c = chroma.map { Double($0 / total) }
        let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func corr(_ p: [Double], _ shift: Int) -> Double {
            let pm = p.reduce(0, +) / 12, cm = c.reduce(0, +) / 12
            var num = 0.0, dp = 0.0, dc = 0.0
            for i in 0..<12 {
                let a = p[(i - shift + 12) % 12] - pm, b = c[i] - cm
                num += a * b; dp += a * a; dc += b * b
            }
            return num / sqrt(dp * dc + 1e-12)
        }
        var bestKey = 0, best = -2.0
        for s in 0..<12 {
            let mj = corr(major, s), mn = corr(minor, s)
            if mj > best { best = mj; bestKey = s }
            if mn > best { best = mn; bestKey = 12 + s }
        }
        return best > 0.3 ? bestKey : nil
    }
}
