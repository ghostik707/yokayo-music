package com.yokayo.music.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import com.yokayo.music.EqPreset
import com.yokayo.music.Prefs
import com.yokayo.music.Track
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.tanh

/** Одна дека: трек в памяти, скорость, громкость, фильтры, эхо, реверб. */
class Deck(private val outSr: Int) {
    @Volatile var track: PcmTrack? = null
    var song: Track? = null
    var analysis: TrackAnalysis? = null
    /** Позиция в кадрах исходного файла. */
    @Volatile var pos = 0.0
    @Volatile var playing = false
    @Volatile var startAt = -1L          // кадр выхода, с которого дека начинает играть
    var rate = 1.0                        // подстройка темпа (DJ)
    var baseRate = 1.0                    // Sped up / Slowed
    var baseReverb = 0f
    @Volatile var finished = false

    var vol = 1f; var gainDb = 0f; var bassDb = 0f; var midDb = 0f
    var hp = 20f; var lp = 20000f; var echoWet = 0f; var echoTime = 0.4; var echoFb = 0.45f; var reverbWet = 0f

    private val bass = Biquad(); private val mid = Biquad(); private val hpf = Biquad(); private val lpf = Biquad()
    private val echo = Echo(outSr); private val reverb = Reverb(outSr)
    private var buf = FloatArray(0)

    val seconds get() = track?.let { pos / it.sampleRate } ?: 0.0
    val duration get() = track?.let { if (it.done) it.duration else it.expectedDuration } ?: 0.0
    val realRate get() = rate * baseRate

    fun load(t: PcmTrack, s: Track, a: TrackAnalysis?) {
        track = t; song = s; analysis = a; pos = 0.0; playing = false; startAt = -1; finished = false
        rate = 1.0; resetFx(); echo.clear()
    }

    fun unload() { playing = false; track = null; song = null; analysis = null; finished = false }

    fun resetFx() {
        vol = 1f; gainDb = 0f; bassDb = 0f; midDb = 0f; hp = 20f; lp = 20000f; echoWet = 0f; echoFb = 0.45f; reverbWet = baseReverb
    }

    fun seek(sec: Double) { track?.let { pos = (sec * it.sampleRate).coerceIn(0.0, max(0.0, it.frames - 1.0)) }; finished = false }

    /** Рендер блока и подмешивание в `out`. */
    fun render(out: FloatArray, frames: Int, clock: Long) {
        val t = track ?: return
        if (!playing) return
        if (buf.size < frames * 2) buf = FloatArray(frames * 2)
        buf.fill(0f, 0, frames * 2)
        val step = realRate * t.sampleRate / outSr
        val d = t.data
        val avail = t.frames
        var p = pos
        var started = false
        for (i in 0 until frames) {
            if (startAt > clock + i) continue
            started = true
            val j = p.toInt()
            if (j + 1 >= avail) { if (t.done) { finished = true; break } else break }
            val f = (p - j).toFloat()
            buf[i * 2] = (d[j * 2] * (1 - f) + d[j * 2 + 2] * f) / 32768f
            buf[i * 2 + 1] = (d[j * 2 + 1] * (1 - f) + d[j * 2 + 3] * f) / 32768f
            p += step
        }
        if (!started && echoWet < 0.01f && reverbWet < 0.01f) return
        pos = p
        // цепочка: громкость до эффектов → бас/середина → срезы → эхо → реверб → фейдер
        val g = (if (gainDb <= -90) 0f else 10f.pow(gainDb / 20))
        if (g != 1f) for (i in 0 until frames * 2) buf[i] *= g
        if (abs(bassDb) > 0.1f) { bass.configure(0, outSr.toDouble(), 180.0, bassDb.toDouble()); bass.process(buf, frames) } else bass.off()
        if (abs(midDb) > 0.1f) { mid.configure(2, outSr.toDouble(), 1500.0, midDb.toDouble(), 1.6); mid.process(buf, frames) } else mid.off()
        if (hp > 21f) { hpf.configure(3, outSr.toDouble(), hp.toDouble()); hpf.process(buf, frames) } else { hpf.off(); hpf.reset() }
        if (lp < 19500f) { lpf.configure(4, outSr.toDouble(), lp.toDouble()); lpf.process(buf, frames) } else { lpf.off(); lpf.reset() }
        echo.process(buf, frames, echoWet, echoTime, if (echoWet > 0.01f) echoFb else 0f)
        reverb.process(buf, frames, reverbWet)
        for (i in 0 until frames * 2) out[i] += buf[i] * vol
    }
}

/** Идущий переход. */
class ActiveTransition(
    val from: Deck, val to: Deck, val plan: MixPlan, val startFrame: Long, val beatFrames: Double,
    val beatSec: Double, val rateB: Double,
) {
    @Volatile var swapped = false
    @Volatile var progress = 0.0
}

/** Звуковой движок: AudioTrack, две деки, переходы по сценарию, эффекты, эквалайзер. */
class Engine {
    val sr = 44100
    val decks = listOf(Deck(sr), Deck(sr))
    val lock = Any()
    @Volatile var clock = 0L; private set
    @Volatile var transition: ActiveTransition? = null
    @Volatile var running = false
    @Volatile var paused = true
    var onSwap: ((ActiveTransition) -> Unit)? = null
    var onComplete: ((ActiveTransition) -> Unit)? = null

    private val fx = mutableListOf<Pair<Long, FxBuffer>>()
    private val eq = List(10) { Biquad() }
    private var eqKey = ""
    private val block = 1024
    private var track: AudioTrack? = null
    private var thread: Thread? = null

    /** Кадр выхода, который слышен сейчас (с поправкой на буфер). */
    val latencyFrames get() = 2L * block

    fun start() {
        if (running) return
        running = true
        val min = AudioTrack.getMinBufferSize(sr, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_FLOAT)
        track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(sr).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setBufferSizeInBytes(max(min, block * 2 * 4 * 2))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        thread = Thread({ loop() }, "yokayo-audio").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    fun resume() { paused = false; track?.play() }
    fun pause() { paused = true; track?.pause() }

    fun schedule(at: Long, b: FxBuffer) = synchronized(lock) { fx += at to b }
    fun clearFx() = synchronized(lock) { fx.clear() }

    private fun loop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
        val out = FloatArray(block * 2)
        while (running) {
            if (paused) { Thread.sleep(20); continue }
            out.fill(0f)
            synchronized(lock) {
                transition?.let { automate(it) }
                for (d in decks) d.render(out, block, clock)
                mixFx(out)
            }
            master(out)
            track?.write(out, 0, out.size, AudioTrack.WRITE_BLOCKING)
            clock += block
        }
    }

    private fun mixFx(out: FloatArray) {
        val it = fx.iterator()
        while (it.hasNext()) {
            val (at, b) = it.next()
            if (at >= clock + block) continue
            val off = (at - clock).toInt()
            for (i in max(0, off) until block) {
                val k = (i - off)
                if (k >= b.frames) break
                out[i * 2] += b.data[k * 2]; out[i * 2 + 1] += b.data[k * 2 + 1]
            }
            if (clock + block - at >= b.frames) it.remove()
        }
    }

    /** Кривые сценария на деки — раз в блок (23 мс). */
    private fun automate(tr: ActiveTransition) {
        if (clock + block <= tr.startFrame) return
        val x = max(0.0, (clock - tr.startFrame) / tr.beatFrames)
        tr.progress = x / tr.plan.totalBeats
        val s = tr.plan.script
        apply(s.a, tr.from, x, s, tr.beatSec)
        apply(s.b, tr.to, x, s, tr.beatSec)
        if (!tr.swapped && x >= s.swap) { tr.swapped = true; onSwap?.invoke(tr) }
        if (x >= tr.plan.totalBeats) {
            transition = null
            tr.from.playing = false
            tr.from.resetFx(); tr.to.resetFx()
            onComplete?.invoke(tr)
        }
    }

    private fun apply(l: DeckLanes, d: Deck, x: Double, s: MixScript, beat: Double) {
        d.vol = l.vol.at(x).coerceIn(0f, 1f)
        d.gainDb = l.gain.at(x)
        d.bassDb = l.bass.at(x); d.midDb = l.mid.at(x)
        d.hp = l.hp.at(x); d.lp = l.lp.at(x)
        val e = l.echo.at(x) / 100f
        if (e > 0.005f) { d.echoTime = min(2.0, beat * s.echoBeats); d.echoFb = s.echoFeedback }
        d.echoWet = e
        d.reverbWet = max(d.baseReverb, l.reverb.at(x) / 100f)
    }

    private fun master(out: FloatArray) {
        val gains = Prefs.gains
        val key = gains.joinToString()
        if (key != eqKey) {
            eqKey = key
            gains.forEachIndexed { i, g ->
                if (abs(g) < 0.05f) eq[i].off()
                else eq[i].configure(if (i == 0) 0 else if (i == 9) 1 else 2, sr.toDouble(), EqPreset.bands[i].toDouble(), g.toDouble(), 1.0)
            }
        }
        for (b in eq) b.process(out, block)
        val pre = 10f.pow((-max(0f, gains.maxOrNull() ?: 0f) * 0.5f + if (Prefs.eqPreset == EqPreset.NIGHT) -4f else 0f) / 20)
        for (i in out.indices) {
            val v = out[i] * pre
            out[i] = if (abs(v) < 0.8f) v else (if (v > 0) 1 else -1) * (0.8f + 0.2f * tanh((abs(v) - 0.8f) / 0.2f))
        }
    }
}
