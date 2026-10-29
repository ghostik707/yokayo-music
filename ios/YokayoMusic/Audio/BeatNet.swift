import Foundation
import Accelerate

/// Yokayo BeatNet — своя нейросеть, которая слышит доли и сильные доли.
/// Обучена с нуля, готовые веса — BeatNet.bin; работает целиком на телефоне:
/// спектр → 8 расширяющихся свёрток (слышит ~12 секунд вокруг) → вероятность доли в каждом кадре.
enum BeatNet {
    static let sr: Double = 11025
    static let n = 1024
    static let hop = 128
    static var fps: Double { sr / Double(hop) }
    private static let channels = 24
    private static let dilations = [1, 2, 4, 8, 16, 32, 64, 128]
    private static let edges = [3, 4, 5, 6, 7, 8, 10, 12, 15, 19, 23, 29, 36, 45, 55, 68, 84, 104, 129, 160, 198, 245, 303, 375, 464]
    private static let bands = 24
    private static let inputs = 48

    /// Путь к весам можно подменить (для проверки на Mac).
    nonisolated(unsafe) static var weightsURL: URL? = Bundle.main.url(forResource: "BeatNet", withExtension: "bin")

    private struct Conv { let k: Int; let d: Int; let ci: Int; let co: Int; let w: [Float]; let b: [Float] }
    private static let layers: [Conv]? = {
        guard let url = weightsURL, let data = try? Data(contentsOf: url) else { return nil }
        let all = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var specs = [(3, 1, inputs, channels)]
        for d in dilations { specs += [(5, d, channels, channels), (1, 1, channels, channels)] }
        specs.append((1, 1, channels, 2))
        var pos = 0
        var out: [Conv] = []
        for (k, d, ci, co) in specs {
            let wn = k * ci * co
            guard pos + wn + co <= all.count else { return nil }
            out.append(Conv(k: k, d: d, ci: ci, co: co, w: Array(all[pos..<pos + wn]), b: Array(all[pos + wn..<pos + wn + co])))
            pos += wn + co
        }
        return pos == all.count ? out : nil
    }()

    static var isAvailable: Bool { layers != nil }

    struct Output { var beat: [Float]; var down: [Float] }

    /// Вероятности доли и сильной доли по кадрам (кадр f — момент (f·hop + n/2) / sr).
    static func run(mono x: [Float]) -> Output? {
        guard let layers else { return nil }
        let (feat, frames) = features(x)
        guard frames > 100 else { return nil }
        var h = conv(layers[0], feat, frames)
        elu(&h)
        for i in 0..<dilations.count {
            var t = conv(layers[1 + 2 * i], h, frames)
            elu(&t)
            let r = conv(layers[2 + 2 * i], t, frames)
            vDSP_vadd(h, 1, r, 1, &h, 1, vDSP_Length(h.count))
        }
        elu(&h)
        let o = conv(layers.last!, h, frames)
        var beat = [Float](repeating: 0, count: frames), down = beat
        for t in 0..<frames {
            beat[t] = 1 / (1 + exp(-o[t * 2]))
            down[t] = 1 / (1 + exp(-o[t * 2 + 1]))
        }
        return Output(beat: beat, down: down)
    }

    // MARK: Признаки — те же, на которых обучалась сеть

    private static func features(_ x: [Float]) -> ([Float], Int) {
        let frames = max(0, (x.count - n) / hop)
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        guard frames > 0, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        var L = [Float](repeating: 0, count: frames * bands)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = re, mag = re
        x.withUnsafeBufferPointer { xp in
            for f in 0..<frames {
                vDSP_vmul(xp.baseAddress! + f * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
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
                for b in 0..<bands {
                    var s: Float = 0
                    for k in edges[b]..<edges[b + 1] { s += mag[k] }
                    L[f * bands + b] = log1p(0.5 * s / Float(edges[b + 1] - edges[b]))   // zrip даёт ×2
                }
            }
        }
        var F = [Float](repeating: 0, count: frames * inputs)
        for f in 0..<frames {
            for b in 0..<bands {
                let v = L[f * bands + b]
                F[f * inputs + b] = v
                F[f * inputs + bands + b] = f == 0 ? 0 : max(0, v - L[(f - 1) * bands + b])
            }
        }
        // нормировка каждого признака по треку
        for c in 0..<inputs {
            var sum: Double = 0, sq: Double = 0
            for f in 0..<frames { let v = Double(F[f * inputs + c]); sum += v; sq += v * v }
            let m = sum / Double(frames)
            let sd = Float(sqrt(max(0, sq / Double(frames) - m * m))) + 1e-3
            for f in 0..<frames { F[f * inputs + c] = (F[f * inputs + c] - Float(m)) / sd }
        }
        return (F, frames)
    }

    // MARK: Свёртка через матричное умножение

    private static func conv(_ l: Conv, _ x: [Float], _ T: Int) -> [Float] {
        let pad = (l.k / 2) * l.d
        var xp = [Float](repeating: 0, count: (T + 2 * pad) * l.ci)
        xp.withUnsafeMutableBufferPointer { p in
            x.withUnsafeBufferPointer { s in (p.baseAddress! + pad * l.ci).update(from: s.baseAddress!, count: T * l.ci) }
        }
        var out = [Float](repeating: 0, count: T * l.co)
        for t in 0..<T { for c in 0..<l.co { out[t * l.co + c] = l.b[c] } }
        xp.withUnsafeBufferPointer { xpp in
            l.w.withUnsafeBufferPointer { wp in
                out.withUnsafeMutableBufferPointer { op in
                    for j in 0..<l.k {
                        let shift = pad + (j - l.k / 2) * l.d
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                                    Int32(T), Int32(l.co), Int32(l.ci), 1,
                                    xpp.baseAddress! + shift * l.ci, Int32(l.ci),
                                    wp.baseAddress! + j * l.ci * l.co, Int32(l.co),
                                    1, op.baseAddress!, Int32(l.co))
                    }
                }
            }
        }
        return out
    }

    private static func elu(_ x: inout [Float]) {
        for i in x.indices where x[i] < 0 { x[i] = exp(x[i]) - 1 }
    }

    // MARK: Сетка из вероятностей

    struct Grid { var bpm: Double; var firstBeat: Double; var confidence: Double }

    /// Темп, фаза и сильная доля по выходу сети. Постоянный темп, как у студийных треков.
    static func grid(_ o: Output) -> Grid? {
        let act = o.beat
        let T = act.count
        guard T > 400 else { return nil }
        // среднее значение сети в точках сетки (период P кадров, сдвиг ph)
        func score(_ P: Double, _ ph: Double, from: Int = 0, to: Int? = nil) -> Float {
            let end = Double((to ?? T) - 1)
            var t = ph
            while t < Double(from) { t += P }
            var sum: Float = 0, cnt: Float = 0
            while t < end {
                let i = Int(t), f = Float(t - Double(i))
                sum += act[i] * (1 - f) + act[i + 1] * f
                cnt += 1
                t += P
            }
            return cnt > 0 ? sum / cnt : 0
        }
        func best(_ bpm: Double, step: Double = 1) -> (Float, Double) {
            let P = 60 * fps / bpm
            var b: Float = -1, bp = 0.0
            var ph = 0.0
            while ph < P { let s = score(P, ph); if s > b { b = s; bp = ph }; ph += step }
            return (b, bp)
        }
        // 1. грубо: автокорреляция вероятностей, 68…185 BPM (как считают диджеи)
        let mean = act.reduce(0, +) / Float(T)
        let centered = act.map { $0 - mean }
        let minLag = Int(60 * fps / 185), maxLag = Int(60 * fps / 68) + 1
        var ac = [Float](repeating: 0, count: maxLag + 2)
        centered.withUnsafeBufferPointer { p in
            for lag in max(1, minLag - 1)...(maxLag + 1) where lag < T {
                var r: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &r, vDSP_Length(T - lag))
                ac[lag] = r / Float(T - lag)
            }
        }
        guard let top = ac[minLag...maxLag].max(), top > 0 else { return nil }
        // 2. темп = самый быстрый пик, почти такой же сильный, как лучший
        //    (у половинного темпа пик той же силы, у двойного — заметно слабее)
        var lag = maxLag
        for l in minLag...maxLag where ac[l] >= ac[l - 1] && ac[l] >= ac[l + 1] && ac[l] >= top * 0.8 { lag = l; break }
        let l0 = ac[lag - 1], c0 = ac[lag], r0 = ac[lag + 1]
        let den = l0 - 2 * c0 + r0
        let exact = Double(lag) + (den != 0 ? Double(max(-0.5, min(0.5, 0.5 * (l0 - r0) / den))) : 0)
        let pick = 60 * fps / exact
        // 3. точно по всему треку: ±1.5 % с шагом 0.02 BPM
        var fine = (bpm: pick, s: Float(-1), ph: 0.0)
        var c = pick * 0.985
        while c <= pick * 1.015 {
            let (s, ph) = best(c, step: 0.5)
            if s > fine.s { fine = (c, s, ph) }
            c += 0.02
        }
        // продюсеры ставят целый BPM — берём его, если сетка не хуже
        let integer = fine.bpm.rounded()
        if abs(integer - fine.bpm) < 0.35 {
            let (s, ph) = best(integer, step: 0.25)
            if s >= fine.s * 0.97 { fine = (integer, s, ph) }
        }
        let P = 60 * fps / fine.bpm
        // 4. уверенность: доли против «междолий» и устойчивость фазы по частям трека
        let on = score(P, fine.ph), off = score(P, fine.ph + P / 2)
        let contrast = Double(max(0, min(1, (on - off) / max(0.001, on))))
        var steady = 0
        let parts = 4
        for k in 0..<parts {
            let a = T * k / parts, b = T * (k + 1) / parts
            var bs: Float = -1, bp = 0.0, ph = 0.0
            while ph < P { let s = score(P, ph, from: a, to: b); if s > bs { bs = s; bp = ph }; ph += 0.5 }
            var diff = (bp - fine.ph) / P
            diff -= diff.rounded()
            if abs(diff) < 0.08 { steady += 1 }
        }
        let strength = Double(min(1, on / 0.35))
        let confidence = contrast * (0.3 + 0.7 * Double(steady) / Double(parts)) * (0.5 + 0.5 * strength)
        // 5. сильная доля: какой из четырёх сдвигов чаще отмечен сетью
        var bestShift = 0, bestDown: Float = -1
        for shift in 0..<4 {
            var sum: Float = 0, cnt: Float = 0
            var t = fine.ph + Double(shift) * P
            while t < Double(T - 1) { sum += o.down[Int(t)]; cnt += 1; t += 4 * P }
            if cnt > 0, sum / cnt > bestDown { bestDown = sum / cnt; bestShift = shift }
        }
        let firstFrame = (fine.ph + Double(bestShift) * P).truncatingRemainder(dividingBy: 4 * P)
        let first = (firstFrame * Double(hop) + Double(n) / 2) / sr
        return Grid(bpm: (fine.bpm * 100).rounded() / 100, firstBeat: first, confidence: confidence)
    }
}
