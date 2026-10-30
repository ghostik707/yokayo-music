import Foundation
import Accelerate

/// TransitionNet — вторая своя нейросеть Yokayo: сама рисует DJ-переход.
/// На каждую из 32 долей окна она получает бас/середину/верх обоих треков, позицию в такте,
/// признаки пары и случайный «вектор настроения», а отдаёт 13 кривых: громкость, бас, середину,
/// фильтры, эхо и реверб обеих дек. Обучена на шаблонах диджеев, затем — по «судье» без шаблонов.
enum TransitionNet {
    static let T = 32
    static let zDim = 8
    static let inputs = 6 + 2 + 4 + 5 + zDim
    private static let C = 48
    private static let dilations = [1, 2, 4, 8, 1, 2]
    static let outputs = 13
    static let channelNames = ["Громкость A", "Бас A", "Середина A", "ВЧ-фильтр A", "НЧ-фильтр A", "Эхо A", "Реверб A", "Сигнал A",
                               "Громкость B", "Бас B", "Середина B", "ВЧ-фильтр B", "НЧ-фильтр B"]

    private struct Conv { let k: Int; let d: Int; let ci: Int; let co: Int; let w: [Float]; let b: [Float] }
    /// Путь к весам можно подменить (для проверки на Mac).
    nonisolated(unsafe) static var weightsURL: URL? = Bundle.main.url(forResource: "TransitionNet", withExtension: "bin")

    private static let layers: [Conv]? = {
        guard let url = weightsURL, let data = try? Data(contentsOf: url) else { return nil }
        let all = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var specs = [(1, 1, inputs, C)]
        for d in dilations { specs += [(3, d, C, C), (1, 1, C, C)] }
        specs.append((1, 1, C, outputs))
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

    /// Признаки пары, как при обучении.
    struct Context {
        var a: [Float]          // T × 3: бас/середина/верх A
        var b: [Float]          // T × 3
        var synced: Float, keyFit: Float, hot: Float, chill: Float, tempoDev: Float
    }

    /// Кривые перехода: T × 13, каждое значение 0…1.
    static func run(_ c: Context, z: [Float]) -> [Float]? {
        guard let layers else { return nil }
        var x = [Float](repeating: 0, count: T * inputs)
        for t in 0..<T {
            let o = t * inputs
            for k in 0..<3 { x[o + k] = c.a[t * 3 + k]; x[o + 3 + k] = c.b[t * 3 + k] }
            let ph = Double(t) / Double(T) * 2 * .pi
            x[o + 6] = Float(sin(ph)); x[o + 7] = Float(cos(ph))
            x[o + 8 + t % 4] = 1
            x[o + 12] = c.synced; x[o + 13] = c.keyFit; x[o + 14] = c.hot; x[o + 15] = c.chill; x[o + 16] = c.tempoDev
            for k in 0..<zDim { x[o + 17 + k] = z[k] }
        }
        var h = conv(layers[0], x); elu(&h)
        for i in 0..<dilations.count {
            var t = conv(layers[1 + 2 * i], h); elu(&t)
            let r = conv(layers[2 + 2 * i], t)
            vDSP_vadd(h, 1, r, 1, &h, 1, vDSP_Length(h.count))
        }
        elu(&h)
        let o = conv(layers.last!, h)
        return o.map { 1 / (1 + exp(-$0)) }
    }

    private static func conv(_ l: Conv, _ x: [Float]) -> [Float] {
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
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(T), Int32(l.co), Int32(l.ci), 1,
                                    xpp.baseAddress! + shift * l.ci, Int32(l.ci), wp.baseAddress! + j * l.ci * l.co, Int32(l.co),
                                    1, op.baseAddress!, Int32(l.co))
                    }
                }
            }
        }
        return out
    }

    private static func elu(_ x: inout [Float]) { for i in x.indices where x[i] < 0 { x[i] = exp(x[i]) - 1 } }

    /// Случайный вектор настроения (нормальное распределение).
    static func randomZ() -> [Float] {
        (0..<zDim).map { _ in
            let u1 = Double.random(in: 1e-9..<1), u2 = Double.random(in: 0..<1)
            return Float(sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
        }
    }
}
