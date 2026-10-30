package com.yokayo.music.audio

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.yokayo.music.Prefs
import com.yokayo.music.Track
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Режим скорости: Sped up / Slowed + reverb. */
enum class SpeedMode(val title: String, val rate: Double, val reverb: Float) {
    NORMAL("Обычная", 1.0, 0f), SPED_UP("Sped up", 1.25, 0f), SLOWED("Slowed + reverb", 0.82, 0.28f)
}

/** Живые значения для DJ-лаборатории. */
class DeckInfo(val title: String, val artist: String, val cover: String?, val bpm: Double?, val key: String?, val level: Float, val filter: String?)
class DjSnapshot(val plan: MixPlan?, val progress: Double, val a: DeckInfo, val b: DeckInfo?, val crossfade: Float)

/** Мозг плеера: очередь, загрузка, анализ, DJ-переходы. Всё на главном потоке, кроме загрузки и звука. */
object PlayerCore {
    private val main = Handler(Looper.getMainLooper())
    private val pool = Executors.newFixedThreadPool(2)
    val engine = Engine()
    private lateinit var ctx: Context

    var queue by mutableStateOf<List<Track>>(emptyList()); private set
    var index by mutableIntStateOf(0); private set
    var current by mutableStateOf<Track?>(null); private set
    var isPlaying by mutableStateOf(false); private set
    var isLoading by mutableStateOf(false); private set
    var position by mutableDoubleStateOf(0.0); private set
    var duration by mutableDoubleStateOf(0.0); private set
    var djStatus by mutableStateOf<String?>(null); private set
    var djDecision by mutableStateOf<String?>(null)
    var lastRecipe by mutableStateOf<MixComposer.Recipe?>(null); private set
    var isWave by mutableStateOf(false); private set
    var repeat by mutableIntStateOf(0); private set          // 0 — выкл, 1 — всё, 2 — один
    var speed by mutableStateOf(SpeedMode.NORMAL); private set
    var demoActive = false; private set

    /** Подписчики: адаптер MediaSession, волна, статистика. */
    var onChange: (() -> Unit)? = null
    var onTrackStarted: ((Track) -> Unit)? = null
    var onTrackEnded: ((Track, Double, Boolean) -> Unit)? = null
    var onNeedMore: (() -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    private var active = 0
    val activeDeck get() = engine.decks[active]
    private class Prepared(val track: Track, val pcm: PcmTrack, var analysis: TrackAnalysis?)
    private var prepared: Prepared? = null
    private var plan: Pair<String, MixPlan>? = null
    private var loadToken = 0
    private var prepToken = 0
    private val pcmCache = LinkedHashMap<String, PcmTrack>()

    fun init(c: Context) {
        if (::ctx.isInitialized) return
        ctx = c.applicationContext
        Decoder.init(ctx); Analyzer.init(ctx); MixBrain.init(ctx); TransitionNet.load(ctx); TnHistory.init(ctx)
        engine.onSwap = { tr -> main.post { swapped(tr) } }
        engine.onComplete = { tr -> main.post { completed(tr) } }
        engine.start()
        tickLoop()
    }

    private fun changed() { onChange?.invoke() }

    // MARK: Загрузка

    private fun pcm(t: Track): PcmTrack {
        synchronized(pcmCache) { pcmCache[t.id]?.let { if (!it.failed) return it } }
        val f = Decoder.file(t.id, com.yokayo.music.Engine.maxKbps())
        val p = Decoder.decode(f)
        synchronized(pcmCache) {
            pcmCache[t.id] = p
            // держим в памяти не больше трёх треков (~40 МБ каждый)
            val keep = setOfNotNull(current?.id, prepared?.track?.id, t.id) + engine.decks.mapNotNull { it.song?.id }
            pcmCache.keys.filter { it !in keep }.forEach { pcmCache.remove(it) }
        }
        return p
    }

    private fun waitPlayable(p: PcmTrack) { var n = 0; while (!p.done && p.frames < p.sampleRate && n++ < 400) Thread.sleep(25) }

    private val djOn get() = Prefs.djEnabled || demoActive

    // MARK: Публичные действия

    fun play(list: List<Track>, startAt: Int = 0, wave: Boolean = false) {
        if (list.isEmpty()) return
        isWave = wave
        queue = list; index = startAt.coerceIn(0, list.size - 1)
        demoActive = false
        startCurrent()
    }

    fun append(more: List<Track>) { queue = queue + more; prepareNext(); changed() }

    fun playNext(t: Track) {
        if (queue.isEmpty()) return play(listOf(t))
        queue = queue.toMutableList().apply { add(index + 1, t) }
        prepared = null; prepareNext(); changed()
    }

    private fun startCurrent(at: Double = 0.0) {
        finishTransitionNow()
        val t = queue.getOrNull(index) ?: return
        val token = ++loadToken
        current = t; isLoading = true; position = at; duration = t.durationMs / 1000.0
        changed()
        val ready = prepared?.takeIf { it.track.id == t.id }
        pool.execute {
            val p = runCatching { ready?.pcm ?: pcm(t) }.getOrNull()
            if (p == null) { main.post { if (token == loadToken) { isLoading = false; onError?.invoke("Не удалось загрузить трек"); changed() } }; return@execute }
            waitPlayable(p)
            main.post {
                if (token != loadToken) return@post
                synchronized(engine.lock) {
                    engine.decks.forEach { it.playing = false }
                    val d = activeDeck
                    d.load(p, t, ready?.analysis ?: Analyzer.cached(t.id))
                    applySpeed(d)
                    d.seek(at)
                    d.playing = true
                }
                prepared = null; plan = null
                isLoading = false; isPlaying = true
                engine.resume()
                onTrackStarted?.invoke(t)
                analyzeCurrent()
                prepareNext()
                changed()
            }
        }
    }

    fun toggle() { if (isPlaying) pause() else resume() }
    fun pause() { engine.pause(); isPlaying = false; changed() }
    fun resume() { if (current == null) return; engine.resume(); isPlaying = true; changed() }

    fun next() {
        if (queue.isEmpty()) return
        MixBrain.userSkipped()
        if (djOn && isPlaying && engine.transition == null && prepared?.analysis != null && activeDeck.analysis != null) {
            beginTransition(urgent = true); return
        }
        current?.let { onTrackEnded?.invoke(it, position, true) }
        val n = nextIndex() ?: return
        index = n; startCurrent()
    }

    fun previous() {
        if (position > 3 || index == 0) { seek(0.0); return }
        index -= 1; startCurrent()
    }

    fun jump(i: Int) { if (i in queue.indices) { index = i; startCurrent() } }

    fun seek(sec: Double) {
        finishTransitionNow()
        synchronized(engine.lock) { activeDeck.seek(sec) }
        position = sec; plan = null; changed()
    }

    fun cycleRepeat() { repeat = (repeat + 1) % 3; prepared = null; prepareNext(); changed() }
    fun shuffleRest() {
        if (queue.size <= index + 2) return
        queue = queue.take(index + 1) + queue.drop(index + 1).shuffled()
        prepared = null; prepareNext(); changed()
    }

    fun changeSpeed(m: SpeedMode) { speed = m; synchronized(engine.lock) { engine.decks.forEach { applySpeed(it) } } }
    private fun applySpeed(d: Deck) { d.baseRate = speed.rate; d.baseReverb = speed.reverb; d.reverbWet = max(d.reverbWet, speed.reverb) }

    private fun nextIndex(): Int? = when {
        repeat == 2 -> index
        index + 1 < queue.size -> index + 1
        repeat == 1 && queue.isNotEmpty() -> 0
        else -> null
    }

    // MARK: Анализ и подготовка следующего

    private fun analyzeCurrent() {
        if (!djOn) return
        val d = activeDeck; val t = d.song ?: return; val p = d.track ?: return
        if (d.analysis != null) return
        pool.execute {
            val a = Analyzer.analyze(t.id, p)
            main.post { if (d.song?.id == t.id) { d.analysis = a; plan = null } }
        }
    }

    fun prepareNext() {
        if (isWave && index >= queue.size - 3) onNeedMore?.invoke()
        val n = nextIndex() ?: return
        if (n == index && repeat != 2) return
        val t = queue[n]
        if (prepared?.track?.id == t.id) return
        val token = ++prepToken
        val smart = djOn && Prefs.djSmartOrder && repeat != 2 && n == index + 1 && queue.size > n + 1
        pool.execute {
            var pick = t
            if (smart) pickSmart(n, token)?.let { pick = it }
            val p = runCatching { pcm(pick) }.getOrNull() ?: return@execute
            val a = if (djOn) Analyzer.analyze(pick.id, p) else Analyzer.cached(pick.id)
            main.post { if (token == prepToken) { prepared = Prepared(pick, p, a); plan = null } }
        }
    }

    /** Умная очередь: из трёх ближайших — тот, что лучше сводится с текущим. */
    private fun pickSmart(n: Int, token: Int): Track? {
        val a = activeDeck.analysis ?: return null
        val cands = queue.subList(n, min(queue.size, n + 3)).toList()
        var best: Pair<Track, Double>? = null
        for (c in cands) {
            if (token != prepToken) return null
            val p = runCatching { pcm(c) }.getOrNull() ?: continue
            val b = Analyzer.analyze(c.id, p) ?: continue
            val s = MixComposer.compatibility(a, b)
            if (s > (best?.second ?: -1.0)) best = c to s
        }
        val b = best?.first ?: return null
        main.post {
            if (token != prepToken) return@post
            val from = queue.indexOfFirst { it.id == b.id }
            if (from > n) { queue = queue.toMutableList().apply { add(n, removeAt(from)) }; djDecision = "ИИ поставил следующим «${b.title}» — лучше всего сводится" }
        }
        return b
    }

    // MARK: Тик

    private fun tickLoop() {
        main.postDelayed({ tick(); tickLoop() }, 100)
    }

    private fun tick() {
        val d = activeDeck
        if (current != null && !isLoading) { position = d.seconds; duration = max(d.duration, 1.0) }
        MixBrain.tick()
        if (!isPlaying) return
        val tr = engine.transition
        if (tr != null) { djStatus = tr.plan.headline; return }
        glide(d)
        if (d.finished) { advance(); return }
        val a = d.analysis; val p = prepared
        if (djOn && repeat != 2 && a != null && p?.analysis != null) {
            var mix = plannedMix(a, p.analysis!!, p.track)
            if (position > mix.aStart + 0.5) { plan = null; mix = plannedMix(a, p.analysis!!, p.track) }
            if (position >= mix.aStart - 0.6 * d.realRate && position < duration - 1) beginTransition(urgent = false)
        } else if (!djOn && Prefs.crossfade >= 1 && p != null && repeat != 2) {
            val end = min(a?.lastSound ?: duration, duration)
            val secs = Prefs.crossfade.toDouble()
            if (end > secs * 3 && position >= end - secs && position < end - 0.5) beginCrossfade(min(secs, end - position))
        }
    }

    /** После перехода темп плавно возвращается к родному. */
    private fun glide(d: Deck) {
        if (!Prefs.djGlide || abs(d.rate - 1) < 0.0005) return
        synchronized(engine.lock) { d.rate += (1 - d.rate).coerceIn(-0.0006, 0.0006) }
    }

    private fun advance() {
        current?.let { onTrackEnded?.invoke(it, duration, false) }
        val n = nextIndex()
        if (n == null) { pause(); return }
        index = n; startCurrent()
    }

    fun plannedMix(a: TrackAnalysis, b: TrackAnalysis, next: Track): MixPlan {
        val key = "${current?.id}>${next.id}"
        plan?.let { if (it.first == key) return it.second }
        val m = composeMix(a, b, activeDeck.realRate, current?.title ?: "", next.title, position)
        plan = key to m
        return m
    }

    val djReady get() = activeDeck.analysis != null && prepared?.analysis != null
    val plannedNext: MixPlan? get() { val a = activeDeck.analysis ?: return null; val p = prepared ?: return null; val b = p.analysis ?: return null; return plannedMix(a, b, p.track) }

    /** Режим DJ: TransitionNet рисует переход сама, иначе — композитор из приёмов. */
    private fun composeMix(a: TrackAnalysis, b: TrackAnalysis, rateA: Double, titleA: String, titleB: String, now: Double, start: Double? = null): MixPlan =
        (if (com.yokayo.music.Prefs.djMode == "tn") NeuralComposer.compose(a, b, rateA, titleA, titleB, now, start) else null)
            ?: MixComposer.compose(a, b, rateA, titleA, titleB, now, start)

    // MARK: Переход

    private fun beginTransition(urgent: Boolean) {
        val p = prepared ?: return
        val aB = p.analysis ?: return
        val from = activeDeck
        val aA = from.analysis ?: return
        val to = engine.decks[1 - active]
        val posA = from.seconds
        val rateA = from.realRate
        var mix = plannedMix(aA, aB, p.track)
        if (urgent || mix.aStart > posA + 1.5) {
            mix = composeMix(aA, aB, rateA, current?.title ?: "", p.track.title, posA, aA.downbeatAtOrAfter(posA + 0.35))
        }
        synchronized(engine.lock) {
            to.load(p.pcm, p.track, aB)
            applySpeed(to)
            val (ratio, _) = MixComposer.tempoRatio(aA.bpm * rateA, aB)
            to.rate = if (mix.synced) ratio / to.baseRate else 1.0
            val aStart = max(mix.aStart, aA.downbeatAtOrAfter(posA + 0.1))
            val sr = engine.sr
            val startFrame = engine.clock + ((aStart - posA) / rateA * sr).toLong()
            val beatSec = aA.beat / rateA
            val beatFrames = beatSec * sr
            val s = mix.script
            to.seek(mix.bStart)
            to.startAt = startFrame + (s.bEnter * beatFrames).toLong()
            // стартовые значения кривых B, чтобы не было щелчка до первого блока автоматизации
            to.vol = s.b.vol.at(0.0); to.gainDb = s.b.gain.at(0.0); to.bassDb = s.b.bass.at(0.0); to.hp = s.b.hp.at(0.0); to.lp = s.b.lp.at(0.0)
            to.playing = true
            scheduleFx(mix, from, aA, aStart, startFrame, beatFrames, beatSec)
            engine.transition = ActiveTransition(from, to, mix, startFrame, beatFrames, beatSec, to.rate)
        }
        prepared = null; plan = null
        mix.recipe?.let { MixBrain.began(it); lastRecipe = it }
        djStatus = mix.headline
        djDecision = "ИИ: " + mix.reason
        changed()
    }

    private fun beginCrossfade(secs: Double) {
        val p = prepared ?: return
        val from = activeDeck; val to = engine.decks[1 - active]
        val mix = MixComposer.crossfade(secs, from.seconds, p.analysis?.mixIn?.let { max(0.0, it - 0.05) } ?: 0.0)
        synchronized(engine.lock) {
            to.load(p.pcm, p.track, p.analysis); applySpeed(to)
            to.seek(mix.bStart); to.vol = 0f; to.startAt = engine.clock; to.playing = true
            // «доля» = секунда реального времени
            engine.transition = ActiveTransition(from, to, mix, engine.clock, engine.sr.toDouble(), 1.0, 1.0)
        }
        prepared = null; plan = null
    }

    private fun scheduleFx(m: MixPlan, from: Deck, aA: TrackAnalysis, aStart: Double, startFrame: Long, beatFrames: Double, beatSec: Double) {
        val gain = Prefs.djFx
        val src = from.track ?: return
        fun at(beat: Double) = startFrame + (beat * beatFrames).toLong()
        fun slice(beat: Double, seconds: Double) = DjBuffers.slice(src, aStart + aA.beat * beat, seconds)
        for (e in m.script.events) {
            val b: FxBuffer? = when (e) {
                is MixEvent.SynthFx -> if (gain < 0.01f) null else when (e.kind) {
                    Synth.RISER -> FxSynth.scaled(FxSynth.riser(beatSec * e.beats), 0.4f * gain)
                    Synth.SNARE_ROLL -> FxSynth.scaled(FxSynth.snareRoll(beatSec * e.beats, beatSec), 0.5f * gain)
                    Synth.IMPACT -> FxSynth.scaled(FxSynth.impact(), 0.6f * gain)
                    Synth.CRASH -> FxSynth.scaled(FxSynth.crash(), 0.45f * gain)
                    Synth.DOWNLIFTER -> FxSynth.scaled(FxSynth.downlifter(beatSec * e.beats), 0.45f * gain)
                    Synth.SUB_DROP -> FxSynth.scaled(FxSynth.subDrop(), 0.55f * gain)
                }
                is MixEvent.Roll -> slice(e.at, aA.beat)?.let { DjBuffers.roll(it, beatSec, e.beats, 1f) }
                is MixEvent.Gate -> slice(e.at, aA.beat * e.beats)?.let { DjBuffers.gate(it, beatSec, 1f) }
                is MixEvent.Brake -> slice(e.at, beatSec * e.beats)?.let { DjBuffers.tapeStop(it, beatSec * e.beats, 1f) }
                is MixEvent.Spin -> slice(e.at - 1.2 / aA.beat, 1.2)?.let { DjBuffers.backspin(it, beatSec * e.beats, 1f) }
            }
            b?.let { engine.schedule(at(max(0.0, e.at)), it) }
        }
    }

    private fun swapped(tr: ActiveTransition) {
        current?.let { onTrackEnded?.invoke(it, position, false) }
        active = engine.decks.indexOf(tr.to)
        val id = tr.to.song?.id
        val n = queue.indexOfFirst { it.id == id }
        index = if (n > index) n else min(index + 1, queue.size - 1)
        current = tr.to.song
        duration = tr.to.duration
        tr.to.song?.let { onTrackStarted?.invoke(it) }
        changed()
    }

    private fun completed(tr: ActiveTransition) {
        tr.plan.recipe?.let { MixBrain.finished(it) }
        djStatus = null
        if (demoActive) demoActive = false
        synchronized(engine.lock) { if (tr.from !== activeDeck) tr.from.unload() }
        prepareNext()
        changed()
    }

    fun finishTransitionNow() {
        val tr = engine.transition ?: return
        synchronized(engine.lock) {
            engine.transition = null
            engine.clearFx()
            if (!tr.swapped) { tr.to.unload(); tr.from.resetFx() }
            else { tr.from.playing = false; tr.from.resetFx(); tr.to.resetFx() }
        }
        if (tr.swapped) active = engine.decks.indexOf(tr.to)
        djStatus = null
        prepareNext()
    }

    // MARK: DJ-лаборатория

    fun playDemo(a: Track, b: Track, done: (String?) -> Unit) {
        finishTransitionNow()
        isWave = false; demoActive = true
        queue = listOf(a, b); index = 0
        val token = ++loadToken
        isLoading = true; current = a; djStatus = "ИИ слушает треки…"; changed()
        pool.execute {
            val pa = runCatching { pcm(a) }.getOrNull(); val pb = runCatching { pcm(b) }.getOrNull()
            val anA = pa?.let { Analyzer.analyze(a.id, it) }; val anB = pb?.let { Analyzer.analyze(b.id, it) }
            main.post {
                if (token != loadToken) return@post
                isLoading = false; djStatus = null
                if (pa == null || pb == null || anA == null || anB == null) { demoActive = false; done("Не удалось подготовить треки"); changed(); return@post }
                prepared = Prepared(b, pb, anB); plan = null
                val mix = composeMix(anA, anB, 1.0, a.title, b.title, 0.0)
                synchronized(engine.lock) {
                    engine.decks.forEach { it.playing = false }
                    activeDeck.load(pa, a, anA); applySpeed(activeDeck)
                    activeDeck.seek(max(0.0, mix.aStart - 8)); activeDeck.playing = true
                }
                plan = "${a.id}>${b.id}" to mix
                isPlaying = true; engine.resume()
                djDecision = "ИИ: " + mix.reason
                done(null); changed()
            }
        }
    }

    fun snapshot(): DjSnapshot {
        fun info(d: Deck, level: Float): DeckInfo {
            val filter = if (d.lp < 19500) "НЧ-фильтр ${d.lp.toInt()} Гц" else if (d.hp > 30) "ВЧ-фильтр ${d.hp.toInt()} Гц"
                else if (d.echoWet > 0.01f) "Эхо ${(d.echoWet * 100).toInt()}%" else if (d.bassDb < -3) "Бас убран" else null
            return DeckInfo(d.song?.title ?: "—", d.song?.artist ?: "", d.song?.coverUrl(200), d.analysis?.let { it.bpm * d.realRate }, d.analysis?.camelot, level, filter)
        }
        engine.transition?.let { tr ->
            val aL = tr.from.vol * (if (tr.from.gainDb <= -90) 0f else 1f)
            val bL = if (tr.progress * tr.plan.totalBeats >= tr.plan.script.bEnter) tr.to.vol else 0f
            return DjSnapshot(tr.plan, tr.progress.coerceIn(0.0, 1.0), info(tr.from, aL), info(tr.to, bL), bL / max(0.0001f, aL + bL))
        }
        val p = prepared
        return DjSnapshot(plannedNext, 0.0, info(activeDeck, if (isPlaying) 1f else 0f),
            p?.let { DeckInfo(it.track.title, it.track.artist, it.track.coverUrl(200), it.analysis?.bpm, it.analysis?.camelot, 0f, null) }, 0f)
    }
}
