import AVFoundation

/// Синтез переходных эффектов прямо на устройстве: райзер, удар, «вжух» вниз.
enum FXSynth {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    private static func buffer(seconds: Double) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(max(1, seconds * format.sampleRate))
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        return b
    }

    /// Шум с поднимающимся фильтром и тоном — нарастание перед сменой трека.
    static func riser(seconds: Double) -> AVAudioPCMBuffer {
        let b = buffer(seconds: seconds)
        let n = Int(b.frameLength), sr = Float(format.sampleRate)
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        var lp1: Float = 0, lp2: Float = 0, hp: Float = 0, prev: Float = 0, phase: Float = 0
        for i in 0..<n {
            let t = Float(i) / Float(n)
            let cutoff = 300 * pow(40, t)                 // 300 Гц → 12 кГц
            let a = 1 - exp(-2 * .pi * cutoff / sr)
            let noise = Float.random(in: -1...1)
            lp1 += a * (noise - lp1); lp2 += a * (lp1 - lp2)
            hp = 0.995 * (hp + lp2 - prev); prev = lp2      // срезаем гул
            let freq = 180 * pow(8, t)
            phase += 2 * .pi * freq / sr
            let tone = sin(phase) * 0.12 * t
            let env = pow(t, 2.2) * (t > 0.97 ? (1 - t) / 0.03 : 1)
            let s = (hp * 0.9 + tone) * env
            let pan = 0.5 + 0.35 * sin(t * 20)
            l[i] = s * (1 - pan) * 1.4; r[i] = s * pan * 1.4
        }
        return b
    }

    /// Удар на сильную долю: низкий «бум» + вспышка шума.
    static func impact() -> AVAudioPCMBuffer {
        let b = buffer(seconds: 2.2)
        let n = Int(b.frameLength), sr = Float(format.sampleRate)
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        var phase: Float = 0, lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            let freq = 45 + 90 * exp(-t * 18)
            phase += 2 * .pi * freq / sr
            let boom = sin(phase) * exp(-t * 2.6)
            let noise = Float.random(in: -1...1)
            lp += 0.25 * (noise - lp)
            let crash = (noise - lp) * exp(-t * 3.5) * 0.35
            let s = tanh(boom * 1.3) * 0.8 + crash
            l[i] = s; r[i] = s * 0.96 + crash * 0.08
        }
        return b
    }

    /// Шум с опускающимся фильтром после смены — «выдох».
    static func downlifter(seconds: Double) -> AVAudioPCMBuffer {
        let b = buffer(seconds: seconds)
        let n = Int(b.frameLength), sr = Float(format.sampleRate)
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        var lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / Float(n)
            let cutoff = 9000 * pow(0.02, t)
            let a = 1 - exp(-2 * .pi * cutoff / sr)
            lp += a * (Float.random(in: -1...1) - lp)
            let env = pow(1 - t, 1.8) * min(1, t * 40)
            l[i] = lp * env * 0.7; r[i] = lp * env * 0.7 * (0.8 + 0.2 * t)
        }
        return b
    }

    /// Снейр-ролл: удары всё чаще (1/4 → 1/32), громче и выше к концу.
    static func snareRoll(seconds: Double, beat: Double) -> AVAudioPCMBuffer {
        let b = buffer(seconds: seconds)
        let n = Int(b.frameLength), sr = format.sampleRate
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        for i in 0..<n { l[i] = 0; r[i] = 0 }
        var t = 0.0
        while t < seconds {
            let k = t / seconds
            let step = k < 0.4 ? beat : k < 0.7 ? beat / 2 : k < 0.88 ? beat / 4 : beat / 8
            let start = Int(t * sr), len = Int(0.09 * sr)
            var lp: Float = 0
            for j in 0..<len where start + j < n {
                let e = exp(-Float(j) / Float(0.025 * sr))
                let noise = Float.random(in: -1...1)
                lp += 0.6 * (noise - lp)
                let tone = sin(2 * .pi * Float(190 + 80 * k) * Float(j) / Float(sr)) * 0.5
                let v = ((noise - lp) * 0.8 + tone) * e * Float(0.25 + 0.75 * k)
                l[start + j] += v; r[start + j] += v * 0.95
            }
            t += step
        }
        return b
    }

    /// Саб-дроп: низкий гул, падающий по высоте (хип-хоп / трэп).
    static func subDrop() -> AVAudioPCMBuffer {
        let b = buffer(seconds: 1.8)
        let n = Int(b.frameLength), sr = Float(format.sampleRate)
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        var phase: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            phase += 2 * .pi * (30 + 60 * exp(-t * 2.2)) / sr
            let v = tanh(sin(phase) * 1.6) * exp(-t * 1.4) * min(1, t * 200)
            l[i] = v; r[i] = v
        }
        return b
    }

    /// Крэш: длинная яркая тарелка.
    static func crash() -> AVAudioPCMBuffer {
        let b = buffer(seconds: 2.4)
        let n = Int(b.frameLength), sr = Float(format.sampleRate)
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        var lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / sr
            let noise = Float.random(in: -1...1)
            lp += 0.3 * (noise - lp)
            let v = (noise - lp) * exp(-t * 1.6) * 0.55
            l[i] = v; r[i] = v * (0.85 + 0.15 * sin(t * 9))
        }
        return b
    }

    static func scaled(_ buf: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer {
        guard let data = buf.floatChannelData else { return buf }
        var g = gain
        for c in 0..<Int(buf.format.channelCount) {
            vDSP_vsmul(data[c], 1, &g, data[c], 1, vDSP_Length(buf.frameLength))
        }
        return buf
    }
}

import Accelerate
