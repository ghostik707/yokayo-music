import AVFoundation
import SwiftUI

/// Плеер: очередь, две деки, экран блокировки, DJ-сведение.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    enum RepeatMode { case off, all, one }

    @Published var queue: [Song] = []
    @Published var index = 0
    @Published var isPlaying = false
    @Published var isLoading = false
    /// Позиция не публикуется: иначе 30 раз в секунду перерисовывается всё приложение.
    /// Полоса прогресса и текст читают её сами через TimelineView.
    var currentTime: Double = 0
    @Published private(set) var seekTick = 0
    @Published var duration: Double = 0
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffled = false
    @Published var liked: Set<String> = []
    @Published var toast: String?
    @Published var djStatus: String?
    @Published var isWave = false

    /// Точная позиция для интерфейса (во время игры — прямо с деки).
    var livePosition: Double { isPlaying ? activeDeck.currentTime : currentTime }

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Song] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    let engine = AVAudioEngine()
    let decks = [Deck(), Deck()]
    var active = 0
    var activeDeck: Deck { decks[active] }
    let masterEQ = Equalizer.make()
    let fxPlayer = AVAudioPlayerNode()
    let fxTrack = AVAudioPlayerNode()       // трюки из звука самого трека: ролл, нарезка, стоп-пластинка
    var lastRecipe: MixComposer.Recipe?
    let fxReverb = AVAudioUnitReverb()

    struct Prepared { let song: Song; let file: AVAudioFile; var analysis: TrackAnalysis? }
    var prepared: Prepared?
    var transition: Transition?
    // DJ v2
    var plan: (key: String, mix: MixPlan)?
    var demoVariant = 0
    var demoActive = false
    @Published var djDecision: String?
    @Published private(set) var speedMode: SpeedMode = SpeedMode(rawValue: UserDefaults.standard.string(forKey: "speedMode") ?? "") ?? .normal
    var glide: (perSecond: Float, last: Date)?

    var loadToken = 0
    var prepareToken = 0
    var originalQueue: [Song] = []
    private var timer: Timer?
    private var lastKnownTime: Double = 0
    private var analyzing: Set<String> = []
    let settings = AppSettings.shared
    lazy var nowPlaying = NowPlaying(player: self)

    private init() {
        // Аудиодвижок поднимаем только при первом воспроизведении:
        // его настройка занимает время и не должна задерживать запуск приложения.
        observeSession()
        nowPlaying.setupRemoteCommands()
    }

    private var graphReady = false
    func ensureGraph() {
        guard !graphReady else { return }
        graphReady = true
        for deck in decks {
            deck.attach(to: engine)
            deck.onFinished = { [weak self] deck, _ in self?.deckFinished(deck) }
        }
        engine.attach(fxPlayer); engine.attach(fxReverb)
        fxReverb.loadFactoryPreset(.largeHall); fxReverb.wetDryMix = 35
        engine.connect(fxPlayer, to: fxReverb, format: FXSynth.format)
        engine.connect(fxReverb, to: engine.mainMixerNode, format: FXSynth.format)
        engine.attach(fxTrack)
        engine.connect(fxTrack, to: engine.mainMixerNode, format: FXSynth.format)
        // общий эквалайзер между микшером и выходом
        engine.attach(masterEQ)
        let outFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: masterEQ, format: outFormat)
        engine.connect(masterEQ, to: engine.outputNode, format: outFormat)
        applyEQ()
        applySpeedToDecks()
        engine.prepare()
    }

    // MARK: Публичные действия

    func play(_ songs: [Song], startAt: Int = 0, shuffle: Bool = false, wave: Bool = false) {
        guard !songs.isEmpty else { return }
        isWave = wave
        originalQueue = songs
        var list = songs
        var start = min(max(0, startAt), songs.count - 1)
        if shuffle {
            list.shuffle()
            start = 0
        }
        shuffled = shuffle
        queue = list
        index = start
        startCurrent()
    }

    // MARK: Sped up / Slowed

    enum SpeedMode: String, CaseIterable, Identifiable {
        case normal, spedUp, slowed
        var id: String { rawValue }
        var title: String { self == .normal ? "Обычная" : self == .spedUp ? "Sped up" : "Slowed + reverb" }
        var icon: String { self == .normal ? "speedometer" : self == .spedUp ? "hare.fill" : "tortoise.fill" }
        var rate: Float { self == .normal ? 1 : self == .spedUp ? 1.22 : 0.85 }
        var reverb: Float { self == .slowed ? 30 : 0 }
    }

    func setSpeed(_ mode: SpeedMode) {
        speedMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "speedMode")
        applySpeedToDecks()
        toast = mode == .normal ? "Обычная скорость" : mode.title
        nowPlaying.update()
    }

    func applySpeedToDecks() {
        for d in decks {
            d.baseVarispeed = speedMode.rate
            d.baseReverb = speedMode.reverb
            if transition == nil { d.varispeed.rate = speedMode.rate; d.reverb.wetDryMix = speedMode.reverb }
        }
    }

    // MARK: DJ-лаборатория

    /// Проиграть показательный переход между двумя выбранными треками.
    /// `variant` меняет «бросок кубика» ИИ — другой рецепт для той же пары.
    func playDemo(_ a: Song, _ b: Song, variant: Int) async {
        finishTransitionNow()
        isWave = false; shuffled = false
        queue = [a, b]; originalQueue = queue; index = 0
        loadToken += 1; prepareToken += 1
        let token = loadToken
        isLoading = true
        djStatus = "ИИ слушает треки…"
        do {
            var pa = try await load(a)
            if pa.analysis == nil { pa.analysis = await BeatAnalyzer.analyze(id: a.id, file: pa.file.url) }
            var pb = try await load(b)
            if pb.analysis == nil { pb.analysis = await BeatAnalyzer.analyze(id: b.id, file: pb.file.url) }
            guard token == loadToken, let anA = pa.analysis, let anB = pb.analysis else { throw URLError(.cannotDecodeContentData) }
            ensureGraph()
            transition = nil; glide = nil
            decks.forEach { $0.stop(); $0.resetFX(); $0.timePitch.rate = 1 }
            let deck = activeDeck
            deck.load(song: a, file: pa.file, analysis: anA, engine: engine)
            prepared = pb
            demoVariant = variant
            demoActive = true
            plan = nil
            let mix = DJPlanner.plan(a: anA, b: anB, rateA: 1, titleA: a.title, titleB: b.title, variant: variant,
                                     classic: !djAIMode, beatsSetting: settings.djBeats, now: 0)
            startEngine()
            deck.schedule(from: max(0, mix.aStart - 8))
            duration = deck.duration
            isPlaying = true
            isLoading = false
            djStatus = nil
            djDecision = (djAIMode ? "ИИ: " : "Классика: ") + mix.reason
            nowPlaying.update()
        } catch {
            guard token == loadToken else { return }
            isLoading = false
            djStatus = nil
            toast = "Не удалось подготовить треки"
        }
    }

    func applyEQ() {
        Equalizer.apply(EQPreset(rawValue: settings.eqPreset) ?? .flat, to: masterEQ)
    }

    /// Живое изменение своих полос, пока тянут ползунок.
    func previewEQ(_ gains: [Float]) {
        Equalizer.apply(gains: gains, to: masterEQ)
    }

    // MARK: Таймер сна

    @Published private(set) var sleepAt: Date?
    @Published private(set) var sleepEndOfTrack = false
    var sleepActive: Bool { sleepAt != nil || sleepEndOfTrack }
    var sleepLabel: String? {
        if sleepEndOfTrack { return "До конца трека" }
        guard let sleepAt else { return nil }
        let m = max(1, Int(sleepAt.timeIntervalSinceNow / 60 + 0.5))
        return "Сон через \(m) мин"
    }
    func setSleep(minutes: Int) { sleepEndOfTrack = false; sleepAt = Date().addingTimeInterval(Double(minutes) * 60); toast = "Таймер сна: \(minutes) мин" }
    func setSleepEndOfTrack() { sleepAt = nil; sleepEndOfTrack = true; toast = "Остановлю после этого трека" }
    func cancelSleep() { sleepAt = nil; sleepEndOfTrack = false; engine.mainMixerNode.outputVolume = 1 }

    /// Последние 8 секунд — плавное затухание, затем пауза.
    private func sleepTick() {
        guard let sleepAt else { return }
        let left = sleepAt.timeIntervalSinceNow
        if left <= 0 {
            pause()
            self.sleepAt = nil
            engine.mainMixerNode.outputVolume = 1
        } else if left < 8 {
            engine.mainMixerNode.outputVolume = Float(left / 8)
        }
    }

    func playWave(seed: Song? = nil) {
        Task {
            do {
                var seedId: String?
                if case .yandex(let id)? = seed?.source { seedId = id.split(separator: ":").first.map(String.init) }
                let songs = try await Wave.shared.start(trackSeed: seedId)
                play(songs, wave: true)
            } catch { toast = "Не удалось запустить «Мою волну»" }
        }
    }

    func playNext(_ song: Song) {
        guard !queue.isEmpty else { play([song]); return }
        queue.insert(song, at: index + 1)
        prepared = nil; prepareNext()
        toast = "Сыграет следующим"
    }

    func addToQueue(_ song: Song) {
        guard !queue.isEmpty else { play([song]); return }
        queue.append(song)
        if index + 1 == queue.count - 1 { prepareNext() }
        toast = "Добавлено в очередь"
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        reportWaveEnd(skipped: true)
        finishTransitionNow()
        index = i
        startCurrent()
    }

    func move(from: IndexSet, to: Int) {
        var upcoming = upNext
        upcoming.move(fromOffsets: from, toOffset: to)
        queue = Array(queue[...index]) + upcoming
        prepared = nil; prepareNext()
    }

    func toggleShuffle() {
        guard let cur = current else { return }
        if shuffled {
            queue = originalQueue
            index = queue.firstIndex(of: cur) ?? 0
        } else {
            originalQueue = queue
            var rest = queue; rest.remove(at: index); rest.shuffle()
            queue = Array(queue[...index]) + rest.filter { !queue[...index].contains($0) }
        }
        shuffled.toggle()
        prepared = nil; prepareNext()
    }

    func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
    }

    func togglePlay() { isPlaying ? pause() : resume() }

    func pause() {
        guard isPlaying else { return }
        finishTransitionNow()
        activeDeck.pause()
        lastKnownTime = activeDeck.currentTime
        engine.pause()
        isPlaying = false
        nowPlaying.update()
    }

    func resume() {
        guard current != nil else { return }
        guard activeDeck.isLoaded else { startCurrent(); return }
        startEngine()
        activeDeck.schedule(from: lastKnownTime)
        isPlaying = true
        nowPlaying.update()
    }

    func seek(to time: Double) {
        finishTransitionNow()
        lastKnownTime = time
        currentTime = time
        seekTick += 1
        if isPlaying { activeDeck.schedule(from: time) } else { activeDeck.schedule(from: time); activeDeck.pause() }
        nowPlaying.update()
    }

    func next() {
        guard !queue.isEmpty else { return }
        MixBrain.shared.userSkipped()
        if settings.djEnabled, isPlaying, transition == nil, prepared?.analysis != nil, activeDeck.analysis != nil {
            beginTransition(beats: 16)
            return
        }
        finishTransitionNow()
        advance(auto: false)
    }

    func previous() {
        if currentTime > 3 || index == 0 { seek(to: 0); return }
        finishTransitionNow()
        index -= 1
        startCurrent()
    }

    func toggleLike(_ song: Song? = nil) {
        guard let song = song ?? current, !song.isLocal else { return }
        let now = !liked.contains(song.id)
        if now { liked.insert(song.id) } else { liked.remove(song.id) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await API.setLike(song, liked: now) }
        nowPlaying.update()
    }

    func loadLikes() async { liked = await API.likedIds() }

    func replaceCurrent(with song: Song) {
        guard queue.indices.contains(index) else { return }
        let t = currentTime
        queue[index] = song
        startCurrent(from: t)
    }

    // MARK: Внутреннее

    func startEngine() {
        ensureGraph()
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
        if !fxPlayer.isPlaying { fxPlayer.play() }
        if !fxTrack.isPlaying { fxTrack.play() }
        startTimer()
    }

    private func startCurrent(from time: Double = 0) {
        guard let song = current else { return }
        ensureGraph()
        loadToken += 1
        let token = loadToken
        transition = nil; glide = nil; djStatus = nil
        decks.forEach { $0.stop(); $0.resetFX(); $0.timePitch.rate = 1 }
        isLoading = true
        currentTime = time; lastKnownTime = time
        duration = Double(song.durationMs) / 1000
        nowPlaying.update()
        Task {
            do {
                let p: Prepared
                if let ready = prepared, ready.song.id == song.id { p = ready } else { p = try await load(song) }
                guard token == loadToken else { return }
                prepared = nil
                let deck = activeDeck
                deck.load(song: song, file: p.file, analysis: p.analysis, engine: engine)
                startEngine()
                deck.schedule(from: time)
                duration = deck.duration
                isPlaying = true
                isLoading = false
                nowPlaying.update()
                prepareNext()
                ensureAnalysis()
                if isWave { Wave.shared.started(song) }
                Task { _ = await LyricsLoader.load(song) }   // текст готов к открытию
            } catch {
                guard token == loadToken else { return }
                isLoading = false
                toast = "Трек «\(song.title)» недоступен"
                if index + 1 < queue.count {
                    try? await Task.sleep(for: .seconds(1))
                    guard token == loadToken else { return }
                    index += 1
                    startCurrent()
                } else {
                    isPlaying = false
                }
            }
        }
    }

    func load(_ song: Song) async throws -> Prepared {
        let url = try await AudioFiles.shared.file(for: song, maxBitrate: settings.streamQuality)
        let file = try AVAudioFile(forReading: url)
        return Prepared(song: song, file: file, analysis: BeatAnalyzer.cached(song.id))
    }

    /// Анализ текущего и следующего трека, если DJ-режим включили посреди песни.
    func ensureAnalysis() {
        guard settings.djEnabled else { return }
        let deck = activeDeck
        if let song = deck.song, deck.analysis == nil, let url = deck.file?.url, !analyzing.contains(song.id) {
            analyzing.insert(song.id)
            Task {
                let a = await BeatAnalyzer.analyze(id: song.id, file: url)
                analyzing.remove(song.id)
                if deck.song?.id == song.id { deck.analysis = a }
            }
        }
        if let p = prepared, p.analysis == nil, !analyzing.contains(p.song.id) {
            analyzing.insert(p.song.id)
            Task {
                let a = await BeatAnalyzer.analyze(id: p.song.id, file: p.file.url)
                analyzing.remove(p.song.id)
                if prepared?.song.id == p.song.id { prepared?.analysis = a }
            }
        }
    }
    var djReady: Bool { activeDeck.analysis != nil && prepared?.analysis != nil }

    /// Перемотать к моменту перед переходом, чтобы услышать сведение.
    func previewTransition() {
        guard let a = activeDeck.analysis else { ensureAnalysis(); toast = "Анализирую трек…"; return }
        guard let pr = prepared, let b = pr.analysis else { seek(to: max(0, a.mixOut(beats: settings.djBeats) - 8)); if !isPlaying { resume() }; return }
        plan = nil
        let mix = DJPlanner.plan(a: a, b: b, rateA: 1, titleA: current?.title ?? "", titleB: pr.song.title, variant: demoVariant,
                                 classic: !djAIMode, beatsSetting: settings.djBeats, now: 0)
        seek(to: max(0, mix.aStart - 8))
        if !isPlaying { resume() }
    }

    private var nextIndex: Int? {
        if repeatMode == .one { return index }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode == .all && !queue.isEmpty ? 0 : nil
    }

    func prepareNext() {
        if isWave, index >= queue.count - 3 { extendWave() }
        guard let n = nextIndex, n != index else { return }
        let song = queue[n]
        if prepared?.song.id == song.id { return }
        prepareToken += 1
        let token = prepareToken
        let smart = settings.djEnabled && settings.djSmartOrder && repeatMode != .one && n == index + 1
        Task {
            var song = song
            if smart, let best = await pickSmartNext(from: n, token: token) { song = best }
            guard var p = try? await load(song), token == prepareToken else { return }
            prepared = p
            if settings.djEnabled, p.analysis == nil {
                p.analysis = await BeatAnalyzer.analyze(id: song.id, file: p.file.url)
                if token == prepareToken, prepared?.song.id == song.id { prepared?.analysis = p.analysis }
            }
        }
    }

    /// Умная очередь: из трёх ближайших треков ставит следующим тот, что лучше сводится с текущим.
    private func pickSmartNext(from n: Int, token: Int) async -> Song? {
        guard let cur = current, let curFile = activeDeck.file?.url else { return nil }
        var curAnalysis = activeDeck.analysis
        if curAnalysis == nil { curAnalysis = await BeatAnalyzer.analyze(id: cur.id, file: curFile) }
        guard let a = curAnalysis else { return nil }
        let candidates = Array(queue[n..<min(queue.count, n + 3)])
        guard candidates.count > 1 else { return nil }
        var best: (song: Song, score: Double)?
        for c in candidates {
            guard token == prepareToken else { return nil }
            guard let p = try? await load(c) else { continue }
            var analysis = p.analysis
            if analysis == nil { analysis = await BeatAnalyzer.analyze(id: c.id, file: p.file.url) }
            guard let b = analysis else { continue }
            let s = DJPlanner.compatibility(a, b)
            if s > (best?.score ?? -1) { best = (c, s) }
        }
        guard let best, token == prepareToken, current?.id == cur.id, queue.indices.contains(n),
              let from = queue.firstIndex(where: { $0.id == best.song.id }), from >= n else { return nil }
        if from == n { return best.song }
        queue.move(fromOffsets: IndexSet(integer: from), toOffset: n)
        djDecision = "ИИ поставил следующим «\(best.song.title)» — лучше всего сводится"
        return best.song
    }

    private var extendingWave = false
    private func extendWave() {
        guard !extendingWave else { return }
        extendingWave = true
        let last: String? = {
            guard case .yandex(let id)? = queue.last?.source else { return nil }
            return id
        }()
        Task {
            defer { extendingWave = false }
            _ = last
            if let more = try? await Wave.shared.more(after: queue) {
                let known = Set(queue.map(\.id))
                queue += more.filter { !known.contains($0.id) }
                prepareNext()
            }
        }
    }

    private func deckFinished(_ deck: Deck) {
        guard deck === activeDeck, transition == nil, isPlaying else { return }
        advance(auto: true)
    }

    /// Сообщить волне, что трек доигран или пропущен.
    func reportWaveEnd(skipped: Bool) {
        guard isWave, let s = current else { return }
        Wave.shared.ended(s, played: skipped ? currentTime : duration, skipped: skipped)
    }

    private func advance(auto: Bool) {
        reportWaveEnd(skipped: !auto)
        if auto, sleepEndOfTrack {
            sleepEndOfTrack = false
            isPlaying = false
            activeDeck.stop()
            engine.pause()
            nowPlaying.update()
            return
        }
        guard let n = nextIndex ?? (auto ? nil : (queue.isEmpty ? nil : 0)) else {
            isPlaying = false
            activeDeck.stop()
            lastKnownTime = 0; currentTime = 0
            nowPlaying.update()
            return
        }
        if n == index { seek(to: 0); if !isPlaying { resume() }; return }
        index = n
        // без DJ: следующий трек сразу на другой деке, без паузы
        active = 1 - active
        startCurrent()
    }

    // MARK: Таймер

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard isPlaying else { return }
        let t = activeDeck.currentTime
        currentTime = t
        lastKnownTime = t
        if let s = current { ListeningStats.shared.add(s, seconds: 1.0 / 30) }
        djTick()
        sleepTick()
    }

    // MARK: Аудиосессия

    private func observeSession() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began { if self.isPlaying { self.pause() } }
                else if opts.contains(.shouldResume) { self.resume() }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasPlaying = self.isPlaying
                self.finishTransitionNow()
                try? self.engine.start()
                if wasPlaying {
                    self.fxPlayer.play(); self.fxTrack.play()
                    self.activeDeck.schedule(from: self.lastKnownTime)
                }
            }
        }
    }
}
