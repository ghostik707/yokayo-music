import AVFoundation

/// Одна «дека»: плеер → varispeed → темп → громкость → эквалайзер/фильтры → эхо → реверб → микшер.
final class Deck {
    let player = AVAudioPlayerNode()
    let varispeed = AVAudioUnitVarispeed()          // скорость вместе с тоном: стоп-плёнка, Sped up / Slowed
    let timePitch = AVAudioUnitTimePitch()
    let trim = AVAudioUnitEQ(numberOfBands: 0)   // нормализация громкости
    let eq = AVAudioUnitEQ(numberOfBands: 4)
    let delay = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()
    let mixer = AVAudioMixerNode()

    /// Базовые значения режима скорости (Sped up / Slowed), к ним возвращаемся после переходов.
    var baseVarispeed: Float = 1
    var baseReverb: Float = 0

    private(set) var file: AVAudioFile?
    private(set) var song: Song?
    var analysis: TrackAnalysis?
    private var startFrame: AVAudioFramePosition = 0
    private var pausedTime: Double = 0
    private(set) var scheduleID = 0
    var onFinished: ((Deck, Int) -> Void)?

    var bass: AVAudioUnitEQFilterParameters { eq.bands[0] }
    var highPass: AVAudioUnitEQFilterParameters { eq.bands[1] }
    var lowPass: AVAudioUnitEQFilterParameters { eq.bands[2] }
    var mid: AVAudioUnitEQFilterParameters { eq.bands[3] }

    init() {
        bass.filterType = .lowShelf; bass.frequency = 180; bass.gain = 0; bass.bypass = false
        highPass.filterType = .highPass; highPass.frequency = 20; highPass.bypass = true
        lowPass.filterType = .lowPass; lowPass.frequency = 20000; lowPass.bypass = true
        mid.filterType = .parametric; mid.frequency = 1500; mid.bandwidth = 1.6; mid.gain = 0; mid.bypass = false
        delay.wetDryMix = 0; delay.feedback = 45; delay.lowPassCutoff = 6000
        timePitch.rate = 1
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 0
    }

    func attach(to engine: AVAudioEngine) {
        [player, varispeed, timePitch, trim, eq, delay, reverb, mixer].forEach(engine.attach)
        engine.connect(varispeed, to: timePitch, format: nil)
        engine.connect(timePitch, to: trim, format: nil)
        engine.connect(trim, to: eq, format: nil)
        engine.connect(eq, to: delay, format: nil)
        engine.connect(delay, to: reverb, format: nil)
        engine.connect(reverb, to: mixer, format: nil)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
    }

    var sampleRate: Double { file?.processingFormat.sampleRate ?? 44100 }
    var duration: Double { file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0 }
    var isLoaded: Bool { file != nil }

    func load(song: Song, file: AVAudioFile, analysis: TrackAnalysis?, engine: AVAudioEngine) {
        stop()
        self.song = song
        self.file = file
        self.analysis = analysis
        trim.globalGain = AppSettings.shared.normalize ? song.normalizationGain : 0
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: varispeed, format: file.processingFormat)
        resetFX()
    }

    func resetFX() {
        bass.gain = 0
        mid.gain = 0
        highPass.bypass = true; highPass.frequency = 20
        lowPass.bypass = true; lowPass.frequency = 20000
        delay.wetDryMix = 0
        eq.globalGain = 0
        mixer.outputVolume = 1
        varispeed.rate = baseVarispeed
        reverb.wetDryMix = baseReverb
    }

    /// Текущая позиция в секундах файла.
    var currentTime: Double {
        guard let file else { return 0 }
        if player.isPlaying, let nodeTime = player.lastRenderTime, let t = player.playerTime(forNodeTime: nodeTime) {
            return min(duration, Double(startFrame + t.sampleTime) / file.processingFormat.sampleRate)
        }
        return pausedTime
    }

    /// Ставит воспроизведение с позиции `time` (сек). `hostTime` — точный момент старта.
    func schedule(from time: Double, at hostTime: UInt64? = nil) {
        guard let file else { return }
        scheduleID += 1
        let id = scheduleID
        player.stop()
        let frame = AVAudioFramePosition(max(0, min(time, duration - 0.05)) * file.processingFormat.sampleRate)
        startFrame = frame
        pausedTime = Double(frame) / file.processingFormat.sampleRate
        let count = AVAudioFrameCount(max(0, file.length - frame))
        guard count > 0 else { onFinished?(self, id); return }
        player.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.scheduleID == id else { return }
                self.onFinished?(self, id)
            }
        }
        if let hostTime { player.play(at: AVAudioTime(hostTime: hostTime)) } else { player.play() }
    }

    func pause() {
        pausedTime = currentTime
        scheduleID += 1
        player.stop()
    }

    func stop() {
        scheduleID += 1
        player.stop()
        pausedTime = 0
    }

    func unload() {
        stop()
        file = nil; song = nil; analysis = nil
    }
}
