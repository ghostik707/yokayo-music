package com.yokayo.music.audio

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ceil
import kotlin.math.ln1p
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** Результат анализа трека для DJ-режима (как TrackAnalysis на iPhone). */
data class TrackAnalysis(
    val bpm: Double,
    val firstBeat: Double,
    val duration: Double,
    val mixIn: Double,
    val lastSound: Double,
    val confidence: Double,
    val key: Int?,
    val barEnergy: FloatArray,
    val barLow: FloatArray,
    val introEndBar: Int,
    val outroStartBar: Int,
    val outroFound: Boolean,
    val beatBands: FloatArray = FloatArray(0),   // по долям: бас, середина, верх — вход TransitionNet
) {
    val beat get() = 60 / bpm
    val bar get() = beat * 4
    fun time(ofBar: Int) = firstBeat + ofBar * bar
    fun bar(at: Double) = max(0, floor((at - firstBeat) / bar).toInt())
    val lastSoundBar get() = bar(lastSound)
    fun downbeatAtOrAfter(t: Double) = firstBeat + max(0.0, ceil((t - firstBeat) / bar)) * bar
    fun beatPhase(t: Double): Double { val x = (t - firstBeat) / beat; return x - floor(x) }

    val camelot: String? get() {
        val k = key ?: return null
        val major = intArrayOf(8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1)
        val minor = intArrayOf(5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10)
        return if (k < 12) "${major[k]}B" else "${minor[k - 12]}A"
    }

    fun meanBarEnergy(from: Int, to: Int): Float {
        val a = max(0, from); val b = min(barEnergy.size, to)
        if (b <= a) return 0f
        var s = 0f; for (i in a until b) s += barEnergy[i]; return s / (b - a)
    }

    val dropJump: Float get() {
        if (introEndBar <= 0) return 1f
        val before = meanBarEnergy(introEndBar - 4, introEndBar); val after = meanBarEnergy(introEndBar, introEndBar + 4)
        return if (before > 0.01f) after / before else 2f
    }

    fun json(): String = JSONObject().put("bpm", bpm).put("firstBeat", firstBeat).put("duration", duration).put("mixIn", mixIn)
        .put("lastSound", lastSound).put("confidence", confidence).put("key", key ?: -1)
        .put("barEnergy", JSONArray(barEnergy.map { it.toDouble() })).put("barLow", JSONArray(barLow.map { it.toDouble() }))
        .put("introEndBar", introEndBar).put("outroStartBar", outroStartBar).put("outroFound", outroFound)
        .put("beatBands", JSONArray(beatBands.map { it.toDouble() })).toString()

    companion object {
        fun keyDistance(a: TrackAnalysis, b: TrackAnalysis): Int? {
            val ca = a.camelot ?: return null; val cb = b.camelot ?: return null
            val na = ca.dropLast(1).toInt(); val nb = cb.dropLast(1).toInt()
            val d = min(abs(na - nb), 12 - abs(na - nb))
            return d + if (ca.last() == cb.last()) 0 else if (d == 0) 1 else 2
        }

        fun parse(s: String): TrackAnalysis = JSONObject(s).let { o ->
            fun arr(k: String) = o.getJSONArray(k).let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } }
            TrackAnalysis(o.getDouble("bpm"), o.getDouble("firstBeat"), o.getDouble("duration"), o.getDouble("mixIn"), o.getDouble("lastSound"),
                o.getDouble("confidence"), o.getInt("key").takeIf { it >= 0 }, arr("barEnergy"), arr("barLow"),
                o.getInt("introEndBar"), o.getInt("outroStartBar"), o.getBoolean("outroFound"), if (o.has("beatBands")) arr("beatBands") else FloatArray(0))
        }
    }
}

/** Yokayo BeatNet — своя нейросеть, которая слышит доли и сильные доли (те же веса, что на iPhone). */
object BeatNet {
    const val SR = 11025.0
    const val N = 1024
    const val HOP = 128
    const val FPS = SR / HOP
    private const val C = 24
    private const val BANDS = 24
    private const val INPUTS = 48
    private val dilations = intArrayOf(1, 2, 4, 8, 16, 32, 64, 128)
    private val edges = intArrayOf(3, 4, 5, 6, 7, 8, 10, 12, 15, 19, 23, 29, 36, 45, 55, 68, 84, 104, 129, 160, 198, 245, 303, 375, 464)

    private class Conv(val k: Int, val d: Int, val ci: Int, val co: Int, val w: FloatArray, val b: FloatArray)
    private var layers: List<Conv>? = null

    fun load(ctx: Context) { if (layers == null) loadBytes(ctx.assets.open("BeatNet.bin").readBytes()) }

    fun loadBytes(bytes: ByteArray) {
        val fb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        val all = FloatArray(fb.remaining()).also { fb.get(it) }
        val specs = mutableListOf(intArrayOf(3, 1, INPUTS, C))
        for (d in dilations) { specs += intArrayOf(5, d, C, C); specs += intArrayOf(1, 1, C, C) }
        specs += intArrayOf(1, 1, C, 2)
        var pos = 0
        val out = mutableListOf<Conv>()
        for ((k, d, ci, co) in specs) {
            val wn = k * ci * co
            out += Conv(k, d, ci, co, all.copyOfRange(pos, pos + wn), all.copyOfRange(pos + wn, pos + wn + co))
            pos += wn + co
        }
        if (pos == all.size) layers = out
    }

    class Output(val beat: FloatArray, val down: FloatArray)

    fun run(x: FloatArray): Output? {
        val layers = layers ?: return null
        val (feat, frames) = features(x)
        if (frames <= 100) return null
        var h = conv(layers[0], feat, frames); elu(h)
        for (i in dilations.indices) {
            val t = conv(layers[1 + 2 * i], h, frames); elu(t)
            val r = conv(layers[2 + 2 * i], t, frames)
            for (j in h.indices) h[j] += r[j]
        }
        elu(h)
        val o = conv(layers.last(), h, frames)
        return Output(FloatArray(frames) { 1 / (1 + exp(-o[it * 2])) }, FloatArray(frames) { 1 / (1 + exp(-o[it * 2 + 1])) })
    }

    private fun features(x: FloatArray): Pair<FloatArray, Int> {
        val frames = max(0, (x.size - N) / HOP)
        if (frames == 0) return FloatArray(0) to 0
        val fft = Fft(N); val win = Fft.hann(N); val mag = FloatArray(N / 2)
        val L = FloatArray(frames * BANDS)
        for (f in 0 until frames) {
            fft.magnitudes(x, f * HOP, win, mag)
            for (b in 0 until BANDS) {
                var s = 0f
                for (k in edges[b] until edges[b + 1]) s += mag[k]
                L[f * BANDS + b] = ln1p(s / (edges[b + 1] - edges[b]))
            }
        }
        val F = FloatArray(frames * INPUTS)
        for (f in 0 until frames) for (b in 0 until BANDS) {
            val v = L[f * BANDS + b]
            F[f * INPUTS + b] = v
            F[f * INPUTS + BANDS + b] = if (f == 0) 0f else max(0f, v - L[(f - 1) * BANDS + b])
        }
        for (c in 0 until INPUTS) {
            var sum = 0.0; var sq = 0.0
            for (f in 0 until frames) { val v = F[f * INPUTS + c].toDouble(); sum += v; sq += v * v }
            val m = sum / frames
            val sd = (sqrt(max(0.0, sq / frames - m * m)) + 1e-3).toFloat()
            for (f in 0 until frames) F[f * INPUTS + c] = (F[f * INPUTS + c] - m.toFloat()) / sd
        }
        return F to frames
    }

    private fun conv(l: Conv, x: FloatArray, T: Int): FloatArray {
        val out = FloatArray(T * l.co)
        for (t in 0 until T) for (c in 0 until l.co) out[t * l.co + c] = l.b[c]
        val half = l.k / 2
        for (j in 0 until l.k) {
            val shift = (j - half) * l.d
            val wOff = j * l.ci * l.co
            val t0 = max(0, -shift); val t1 = min(T, T - shift)
            for (t in t0 until t1) {
                val xo = (t + shift) * l.ci
                val oo = t * l.co
                for (ci in 0 until l.ci) {
                    val xv = x[xo + ci]
                    if (xv == 0f) continue
                    val wo = wOff + ci * l.co
                    for (co in 0 until l.co) out[oo + co] += xv * l.w[wo + co]
                }
            }
        }
        return out
    }

    private fun elu(x: FloatArray) { for (i in x.indices) if (x[i] < 0) x[i] = exp(x[i]) - 1 }

    class Grid(val bpm: Double, val firstBeat: Double, val confidence: Double)

    fun grid(o: Output): Grid? {
        val act = o.beat; val T = act.size
        if (T <= 400) return null
        fun score(P: Double, ph: Double, from: Int = 0, to: Int = T): Float {
            val end = (to - 1).toDouble()
            var t = ph
            while (t < from) t += P
            var sum = 0f; var cnt = 0f
            while (t < end) { val i = t.toInt(); val f = (t - i).toFloat(); sum += act[i] * (1 - f) + act[i + 1] * f; cnt++; t += P }
            return if (cnt > 0) sum / cnt else 0f
        }
        fun best(bpm: Double, step: Double): Pair<Float, Double> {
            val P = 60 * FPS / bpm
            var b = -1f; var bp = 0.0; var ph = 0.0
            while (ph < P) { val s = score(P, ph); if (s > b) { b = s; bp = ph }; ph += step }
            return b to bp
        }
        val mean = act.average().toFloat()
        val cen = FloatArray(T) { act[it] - mean }
        val minLag = (60 * FPS / 185).toInt(); val maxLag = (60 * FPS / 68).toInt() + 1
        val ac = FloatArray(maxLag + 2)
        for (lag in max(1, minLag - 1)..(maxLag + 1)) {
            if (lag >= T) continue
            var r = 0f
            for (i in 0 until T - lag) r += cen[i] * cen[i + lag]
            ac[lag] = r / (T - lag)
        }
        val top = (minLag..maxLag).maxOf { ac[it] }
        if (top <= 0) return null
        var lag = maxLag
        for (l in minLag..maxLag) if (ac[l] >= ac[l - 1] && ac[l] >= ac[l + 1] && ac[l] >= top * 0.8f) { lag = l; break }
        val l0 = ac[lag - 1]; val c0 = ac[lag]; val r0 = ac[lag + 1]
        val den = l0 - 2 * c0 + r0
        val exact = lag + if (den != 0f) (0.5f * (l0 - r0) / den).coerceIn(-0.5f, 0.5f).toDouble() else 0.0
        val pick = 60 * FPS / exact
        var fBpm = pick; var fS = -1f; var fPh = 0.0
        var c = pick * 0.985
        while (c <= pick * 1.015) { val (s, ph) = best(c, 0.5); if (s > fS) { fBpm = c; fS = s; fPh = ph }; c += 0.02 }
        val integer = fBpm.roundToInt().toDouble()
        if (abs(integer - fBpm) < 0.35) { val (s, ph) = best(integer, 0.25); if (s >= fS * 0.97f) { fBpm = integer; fS = s; fPh = ph } }
        val P = 60 * FPS / fBpm
        val on = score(P, fPh); val off = score(P, fPh + P / 2)
        val contrast = ((on - off) / max(0.001f, on)).coerceIn(0f, 1f).toDouble()
        var steady = 0
        for (k in 0 until 4) {
            val a = T * k / 4; val b = T * (k + 1) / 4
            var bs = -1f; var bp = 0.0; var ph = 0.0
            while (ph < P) { val s = score(P, ph, a, b); if (s > bs) { bs = s; bp = ph }; ph += 0.5 }
            var diff = (bp - fPh) / P
            diff -= Math.rint(diff)
            if (abs(diff) < 0.08) steady++
        }
        val strength = min(1.0, on / 0.35)
        val confidence = contrast * (0.3 + 0.7 * steady / 4) * (0.5 + 0.5 * strength)
        var bestShift = 0; var bestDown = -1f
        for (shift in 0 until 4) {
            var sum = 0f; var cnt = 0f
            var t = fPh + shift * P
            while (t < T - 1) { sum += o.down[t.toInt()]; cnt++; t += 4 * P }
            if (cnt > 0 && sum / cnt > bestDown) { bestDown = sum / cnt; bestShift = shift }
        }
        val firstFrame = (fPh + bestShift * P) % (4 * P)
        return Grid(Math.rint(fBpm * 100) / 100, (firstFrame * HOP + N / 2) / SR, confidence)
    }
}

/** Анализ трека: BeatNet + громкость по тактам, интро/аутро, тональность. Результат кэшируется. */
object Analyzer {
    private lateinit var dir: File
    private val mem = java.util.concurrent.ConcurrentHashMap<String, TrackAnalysis>()

    fun init(ctx: Context) { dir = File(ctx.filesDir, "analysis2").apply { mkdirs() }; BeatNet.load(ctx) }

    private fun file(id: String) = File(dir, id.replace(":", "_") + ".json")

    fun cached(id: String): TrackAnalysis? = mem[id] ?: runCatching { TrackAnalysis.parse(file(id).readText()) }.getOrNull()?.also { mem[id] = it }

    /** Блокирует поток: ждёт полного декодирования и считает. */
    fun analyze(id: String, track: PcmTrack): TrackAnalysis? {
        cached(id)?.let { return it }
        while (!track.done) Thread.sleep(50)
        if (track.failed || track.frames < 44100 * 10) return null
        val a = runCatching { compute(track.mono11k()) }.getOrNull() ?: return null
        mem[id] = a
        runCatching { file(id).writeText(a.json()) }
        return a
    }

    private const val SR = 11025.0

    fun compute(mono: FloatArray): TrackAnalysis {
        val duration = mono.size / SR
        val fps = SR / 128
        // спектр: громкость, бас
        val n = 1024; val half = n / 2
        val fft = Fft(n); val win = Fft.hann(n); val mag = FloatArray(half)
        val frames = max(0, (mono.size - n) / 128)
        val rms = FloatArray(frames); val lowRMS = FloatArray(frames); val midRMS = FloatArray(frames); val highRMS = FloatArray(frames)
        val lowBins = (150 / (SR / n)).toInt(); val midBins = (2000 / (SR / n)).toInt()
        for (f in 0 until frames) {
            fft.magnitudes(mono, f * 128, win, mag)
            var e = 0f; var le = 0f; var me = 0f; var he = 0f
            for (k in 1 until half) { val m = mag[k] * 2; val p = m * m; e += p; if (k <= lowBins) le += p else if (k <= midBins) me += p else he += p }
            rms[f] = sqrt(e / half); lowRMS[f] = sqrt(le / max(1, lowBins))
            midRMS[f] = sqrt(me / max(1, midBins - lowBins)); highRMS[f] = sqrt(he / max(1, half - midBins))
        }
        val g = BeatNet.run(mono)?.let { BeatNet.grid(it) } ?: throw IllegalStateException("grid")
        val bpm = g.bpm; val firstBeat = g.firstBeat
        val bar = 60 / bpm * 4
        val perSec = fps.toInt()
        val energy = (0 until frames step perSec).map { i -> var s = 0f; val e = min(frames, i + perSec); for (j in i until e) s += rms[j]; s / (e - i) }.toMutableList()
        val peak = energy.maxOrNull() ?: 1f
        if (peak > 0) for (i in energy.indices) energy[i] /= peak
        val nBars = max(1, ((duration - firstBeat) / bar).toInt())
        fun barMean(x: FloatArray, k: Int): Float {
            val a = ((firstBeat + k * bar) * fps).toInt(); val b = min(x.size, ((firstBeat + (k + 1) * bar) * fps).toInt())
            if (b <= a || a < 0) return 0f
            var s = 0f; for (i in a until b) s += x[i]; return s / (b - a)
        }
        var barEnergy = FloatArray(nBars) { barMean(rms, it) }
        var barLow = FloatArray(nBars) { barMean(lowRMS, it) }
        val bp = barEnergy.maxOrNull() ?: 1f; val lp = barLow.maxOrNull() ?: 1f
        barEnergy = FloatArray(nBars) { barEnergy[it] / max(0.0001f, bp) }
        barLow = FloatArray(nBars) { barLow[it] / max(0.0001f, lp) }

        val sorted = energy.sorted()
        val median = sorted[sorted.size / 2]
        val firstSound = (energy.indexOfFirst { it > median * 0.35f }.takeIf { it >= 0 } ?: 0).toDouble()
        val lastSound = min(duration, ((energy.indexOfLast { it > median * 0.35f }.takeIf { it >= 0 } ?: (energy.size - 1)) + 1).toDouble())

        val body = barEnergy.copyOfRange(nBars / 5, max(nBars / 5 + 1, nBars * 4 / 5).coerceAtMost(nBars)).sorted().let { it[it.size / 2] }
        fun mean(a: Int, b: Int, x: FloatArray): Float { val lo = max(0, a); val hi = min(x.size, b); if (hi <= lo) return 0f; var s = 0f; for (i in lo until hi) s += x[i]; return s / (hi - lo) }
        var introEnd = 0
        for (step in intArrayOf(8, 4)) {
            if (introEnd != 0) break
            var k = step
            while (k <= min(64, nBars / 2)) {
                val before = mean(k - step, k, barEnergy); val after = mean(k, k + step, barEnergy)
                val lowBefore = mean(k - step, k, barLow); val lowAfter = mean(k, k + step, barLow)
                if (after >= body * 0.85f && (before < body * 0.75f || lowAfter > lowBefore * 1.4f)) { introEnd = k; break }
                k += step
            }
        }
        val lastBar = ((lastSound - firstBeat) / bar).toInt()
        var outroStart = 0
        for (step in intArrayOf(8, 4)) {
            if (outroStart != 0) break
            var k = (lastBar / step) * step
            while (k > max(nBars * 2 / 3, lastBar - 24)) {
                val before = mean(k - step, k, barEnergy); val after = mean(k, min(lastBar, k + step), barEnergy)
                val lowBefore = mean(k - step, k, barLow); val lowAfter = mean(k, min(lastBar, k + step), barLow)
                if (before >= body * 0.8f && (after < body * 0.7f || lowAfter < lowBefore * 0.6f)) { outroStart = k; break }
                k -= step
            }
        }
        val outroFound = outroStart > 0
        if (outroStart == 0) outroStart = max(nBars * 2 / 3, ((lastBar - 8) / 4) * 4)
        val key = detectKey(chroma(mono))
        val beat = 60 / bpm
        val nBeats = max(1, ((duration - firstBeat) / beat).toInt())
        val bands = FloatArray(nBeats * 3)
        listOf(lowRMS, midRMS, highRMS).forEachIndexed { c, x ->
            var peak = 0.0001f
            for (k in 0 until nBeats) {
                val lo = ((firstBeat + k * beat) * fps).toInt(); val hi = min(x.size, ((firstBeat + (k + 1) * beat) * fps).toInt())
                var v = 0f
                if (hi > lo && lo >= 0) { for (i in lo until hi) v += x[i]; v /= (hi - lo) }
                bands[k * 3 + c] = v; peak = max(peak, v)
            }
            for (k in 0 until nBeats) bands[k * 3 + c] /= peak
        }
        val tmp = TrackAnalysis(bpm, firstBeat, duration, 0.0, lastSound, g.confidence, key, barEnergy, barLow, introEnd, outroStart, outroFound, bands)
        val mixIn = tmp.downbeatAtOrAfter(max(0.0, firstSound - 0.05))
        return tmp.copy(mixIn = if (mixIn < duration * 0.25) mixIn else firstBeat)
    }

    private fun chroma(x: FloatArray): FloatArray {
        val n = 4096; val half = n / 2
        val fft = Fft(n); val win = Fft.hann(n); val mag = FloatArray(half)
        val binHz = SR / n
        val noteOfBin = IntArray(half) { k ->
            val f = k * binHz
            if (f < 65 || f > 2000) -1 else {
                val midi = 69 + 12 * log2(f / 440)
                if (abs(midi - Math.rint(midi)) >= 0.3) -1 else ((Math.rint(midi).toInt() % 12) + 12) % 12
            }
        }
        val total = FloatArray(12)
        var pos = 0
        while (pos + n < x.size) {
            fft.magnitudes(x, pos, win, mag)
            val c = FloatArray(12)
            for (k in 1 until half) if (noteOfBin[k] >= 0) c[noteOfBin[k]] += ln1p(mag[k] * 3.266f)   // как vDSP: zrip ×2 и окно HANN_NORM ×1.633
            val m = c.average().toFloat()
            val sd = sqrt(c.map { (it - m) * (it - m) }.sum() / 12)
            if (sd > 0) for (i in 0 until 12) total[i] += max(0f, (c[i] - m) / sd)
            pos += n
        }
        return total
    }

    private fun detectKey(chroma: FloatArray): Int? {
        val total = chroma.sum()
        if (total <= 0) return null
        val c = chroma.map { (it / total).toDouble() }
        val major = doubleArrayOf(6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88)
        val minor = doubleArrayOf(6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17)
        fun corr(p: DoubleArray, shift: Int): Double {
            val pm = p.average(); val cm = c.average()
            var num = 0.0; var dp = 0.0; var dc = 0.0
            for (i in 0 until 12) { val a = p[(i - shift + 12) % 12] - pm; val b = c[i] - cm; num += a * b; dp += a * a; dc += b * b }
            return num / sqrt(dp * dc + 1e-12)
        }
        var bestKey = 0; var best = -2.0
        for (s in 0 until 12) {
            val mj = corr(major, s); val mn = corr(minor, s)
            if (mj > best) { best = mj; bestKey = s }
            if (mn > best) { best = mn; bestKey = 12 + s }
        }
        return if (best > 0.3) bestKey else null
    }

}
