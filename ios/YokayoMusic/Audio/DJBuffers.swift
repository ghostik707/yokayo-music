import AVFoundation

/// Эффекты из звука самого трека: заикание бита (луп-ролл) и перемотка назад.
enum DJBuffers {
    /// Кусок трека в формате эффект-плеера (44.1 кГц стерео).
    static func slice(of url: URL, at time: Double, seconds: Double) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, time) * sr)
        let count = AVAudioFrameCount(seconds * sr)
        guard start + AVAudioFramePosition(count) < file.length,
              let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        file.framePosition = start
        guard (try? file.read(into: src, frameCount: count)) != nil else { return nil }
        let out = FXSynth.format
        guard let conv = AVAudioConverter(from: file.processingFormat, to: out),
              let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(Double(count) * out.sampleRate / sr) + 64) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: dst, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return src
        }
        return err == nil ? dst : nil
    }

    /// Первые `seconds` буфера с короткими затуханиями по краям (без щелчков).
    static func head(_ b: AVAudioPCMBuffer, seconds: Double, gain: Float) -> AVAudioPCMBuffer? {
        let n = min(b.frameLength, AVAudioFrameCount(seconds * b.format.sampleRate))
        guard n > 0, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: n) else { return nil }
        out.frameLength = n
        let fade = min(Int(n) / 4, Int(0.003 * b.format.sampleRate))
        for c in 0..<Int(b.format.channelCount) {
            let s = b.floatChannelData![c], d = out.floatChannelData![c]
            for i in 0..<Int(n) {
                var g = gain
                if i < fade { g *= Float(i) / Float(fade) }
                if i > Int(n) - fade { g *= Float(Int(n) - i) / Float(fade) }
                d[i] = s[i] * g
            }
        }
        return out
    }

    /// Перемотка назад: звук задом наперёд с разгоном и затуханием.
    static func backspin(from b: AVAudioPCMBuffer, seconds: Double, gain: Float) -> AVAudioPCMBuffer? {
        let sr = b.format.sampleRate
        let n = AVAudioFrameCount(seconds * sr)
        guard let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: n) else { return nil }
        out.frameLength = n
        let srcLen = Int(b.frameLength)
        for c in 0..<Int(b.format.channelCount) {
            let s = b.floatChannelData![c], d = out.floatChannelData![c]
            var pos = Double(srcLen - 1)       // идём с конца к началу
            for i in 0..<Int(n) {
                let t = Double(i) / Double(n)
                let speed = 1 + 3.5 * t * t    // разгон
                let i0 = max(0, min(srcLen - 2, Int(pos)))
                let f = Float(pos - Double(i0))
                let v = s[i0] * (1 - f) + s[i0 + 1] * f
                let env = Float(min(1, t * 30)) * Float(t > 0.55 ? max(0, (1 - t) / 0.45) : 1)
                d[i] = v * env * gain
                pos -= speed
                if pos < 1 { pos = Double(srcLen - 1) }
            }
        }
        return out
    }
}
