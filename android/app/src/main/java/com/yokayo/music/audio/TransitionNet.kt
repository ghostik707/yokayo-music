package com.yokayo.music.audio

import android.content.Context
import org.json.JSONArray
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/** TransitionNet — вторая своя нейросеть Yokayo: сама рисует DJ-переход (те же веса, что на iPhone). */
object TransitionNet {
    const val T = 32
    const val Z = 8
    const val INPUTS = 6 + 2 + 4 + 5 + Z
    private const val C = 48
    private val dilations = intArrayOf(1, 2, 4, 8, 1, 2)
    const val OUT = 13
    val channelNames = listOf("Громкость A", "Бас A", "Середина A", "ВЧ-фильтр A", "НЧ-фильтр A", "Эхо A", "Реверб A", "Сигнал A",
        "Громкость B", "Бас B", "Середина B", "ВЧ-фильтр B", "НЧ-фильтр B")

    private class Conv(val k: Int, val d: Int, val ci: Int, val co: Int, val w: FloatArray, val b: FloatArray)
    private var layers: List<Conv>? = null
    val isAvailable get() = layers != null

    fun load(ctx: Context) { if (layers == null) runCatching { loadBytes(ctx.assets.open("TransitionNet.bin").readBytes()) } }

    fun loadBytes(bytes: ByteArray) {
        val fb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        val all = FloatArray(fb.remaining()).also { fb.get(it) }
        val specs = mutableListOf(intArrayOf(1, 1, INPUTS, C))
        for (d in dilations) { specs += intArrayOf(3, d, C, C); specs += intArrayOf(1, 1, C, C) }
        specs += intArrayOf(1, 1, C, OUT)
        var pos = 0
        val out = mutableListOf<Conv>()
        for ((k, d, ci, co) in specs) {
            val wn = k * ci * co
            if (pos + wn + co > all.size) return
            out += Conv(k, d, ci, co, all.copyOfRange(pos, pos + wn), all.copyOfRange(pos + wn, pos + wn + co)); pos += wn + co
        }
        if (pos == all.size) layers = out
    }

    class Ctx(val a: FloatArray, val b: FloatArray, val synced: Float, val keyFit: Float, val hot: Float, val chill: Float, val tempoDev: Float)

    fun run(c: Ctx, z: FloatArray): FloatArray? {
        val ls = layers ?: return null
        val x = FloatArray(T * INPUTS)
        for (t in 0 until T) {
            val o = t * INPUTS
            for (k in 0 until 3) { x[o + k] = c.a[t * 3 + k]; x[o + 3 + k] = c.b[t * 3 + k] }
            val ph = t.toDouble() / T * 2 * Math.PI
            x[o + 6] = sin(ph).toFloat(); x[o + 7] = cos(ph).toFloat()
            x[o + 8 + t % 4] = 1f
            x[o + 12] = c.synced; x[o + 13] = c.keyFit; x[o + 14] = c.hot; x[o + 15] = c.chill; x[o + 16] = c.tempoDev
            for (k in 0 until Z) x[o + 17 + k] = z[k]
        }
        var h = conv(ls[0], x); elu(h)
        for (i in dilations.indices) {
            val t = conv(ls[1 + 2 * i], h); elu(t)
            val r = conv(ls[2 + 2 * i], t)
            for (j in h.indices) h[j] += r[j]
        }
        elu(h)
        val o = conv(ls.last(), h)
        return FloatArray(o.size) { 1 / (1 + exp(-o[it])) }
    }

    private fun conv(l: Conv, x: FloatArray): FloatArray {
        val out = FloatArray(T * l.co)
        for (t in 0 until T) for (c in 0 until l.co) out[t * l.co + c] = l.b[c]
        val half = l.k / 2
        for (j in 0 until l.k) {
            val shift = (j - half) * l.d
            val wOff = j * l.ci * l.co
            for (t in max(0, -shift) until min(T, T - shift)) {
                val xo = (t + shift) * l.ci; val oo = t * l.co
                for (ci in 0 until l.ci) {
                    val xv = x[xo + ci]; if (xv == 0f) continue
                    val wo = wOff + ci * l.co
                    for (co in 0 until l.co) out[oo + co] += xv * l.w[wo + co]
                }
            }
        }
        return out
    }

    private fun elu(x: FloatArray) { for (i in x.indices) if (x[i] < 0) x[i] = exp(x[i]) - 1 }

    fun randomZ() = FloatArray(Z) {
        val u1 = Random.nextDouble(1e-9, 1.0); val u2 = Random.nextDouble()
        (sqrt(-2 * ln(u1)) * cos(2 * Math.PI * u2)).toFloat()
    }
}

/** Отпечатки последних переходов — чтобы сеть не повторялась. */
object TnHistory {
    private lateinit var p: android.content.SharedPreferences
    var items = listOf<FloatArray>(); private set
    var styles = listOf<String>(); private set
    fun addStyle(s: String) { styles = (styles + s).takeLast(6); if (::p.isInitialized) p.edit().putString("s", styles.joinToString(",")).apply() }
    fun init(ctx: Context) {
        if (::p.isInitialized) return
        p = ctx.getSharedPreferences("tn", Context.MODE_PRIVATE)
        styles = p.getString("s", "")!!.split(",").filter { it.isNotEmpty() }
        items = runCatching { JSONArray(p.getString("h", "[]")).let { a -> (0 until a.length()).map { i -> a.getJSONArray(i).let { r -> FloatArray(r.length()) { r.getDouble(it).toFloat() } } } } }.getOrDefault(emptyList())
    }
    fun add(s: FloatArray) {
        items = (items + listOf(s)).takeLast(6)
        if (::p.isInitialized) p.edit().putString("h", JSONArray(items.map { JSONArray(it.map { v -> v.toDouble() }) }).toString()).apply()
    }
}

/** Переход, нарисованный TransitionNet: 12 «настроений» → 12 переходов → лучший по «судье» и новизне. */
object NeuralComposer {
    const val SAMPLES = 24

    fun compose(a: TrackAnalysis, b: TrackAnalysis, rateA: Double, titleA: String, titleB: String, now: Double, start: Double? = null): MixPlan? {
        val T = TransitionNet.T; val K = TransitionNet.OUT
        val nA = a.beatBands.size / 3; val nB = b.beatBands.size / 3
        if (!TransitionNet.isAvailable || nA < T + 4 || nB < T) return null
        val bpmA = a.bpm * rateA
        val (ratio, _) = MixComposer.tempoRatio(bpmA, b)
        var a0 = if (start != null) Math.rint((start - a.firstBeat) / a.beat).toInt() else {
            var bar = a.outroStartBar - 4
            if (bar + 8 > a.lastSoundBar + 1) bar = a.lastSoundBar + 1 - 8
            max(bar, a.bar(now) + 2) * 4
        }
        a0 = a0.coerceIn(0, (nA - T) / 4 * 4)
        val b0 = (max(0, b.introEndBar * 4 - 16) / 4 * 4).coerceIn(0, (nB - T) / 4 * 4)
        val keyFit = when (TrackAnalysis.keyDistance(a, b)) { 0 -> 1f; 1 -> 0.85f; 2 -> 0.5f; null -> 0.6f; else -> 0.25f }
        val synced = abs(ratio - 1) <= 0.08 && a.confidence >= 0.5 && b.confidence >= 0.5
        val hot = b.dropJump >= 1.5f
        val wa = a.beatBands.copyOfRange(a0 * 3, (a0 + T) * 3); val wb = b.beatBands.copyOfRange(b0 * 3, (b0 + T) * 3)
        fun mean(x: FloatArray, from: Int, to: Int): Float { var s = 0f; for (t in from until to) s += (x[t * 3] + x[t * 3 + 1] + x[t * 3 + 2]) / 3; return s / (to - from) }
        val chill = !hot && (bpmA < 100 || (mean(wa, T - 8, T) < 0.45f && mean(wb, 0, 8) < 0.45f))
        val c = TransitionNet.Ctx(wa, wb, if (synced) 1f else 0f, keyFit, if (hot) 1f else 0f, if (chill) 1f else 0f, min(1.0, abs(ratio - 1) / 0.08).toFloat())
        val history = TnHistory.items
        val cands = (0 until SAMPLES).mapNotNull {
            val y = TransitionNet.run(c, TransitionNet.randomZ()) ?: return@mapNotNull null
            val sig = signature(y)
            var sc = evaluate(y, c)
            history.reversed().forEachIndexed { i, h ->
                var d = 0f; for (j in sig.indices) d += abs(h[j] - sig[j]); d /= sig.size
                sc -= max(0f, 1 - d / 0.12f) * 0.4 * 0.8.pow(i)
            }
            y to sc
        }.sortedByDescending { it.second }
        if (cands.isEmpty()) return null
        // почти такие же хорошие, но другого стиля, чем последние переходы — в приоритете
        val recent = TnHistory.styles.takeLast(2).toSet()
        val fresh = cands.filter { it.second >= cands[0].second - 0.06 && styleOf(it.first) !in recent }
        val y = (if (fresh.isEmpty()) cands[Random.nextInt(min(3, cands.size))] else fresh[Random.nextInt(min(3, fresh.size))]).first
        TnHistory.addStyle(styleOf(y))
        fun v(t: Int, k: Int) = y[t * K + k]
        val s = MixScript((T + 4).toDouble(), 0.0, 0.0)
        val pts = DoubleArray(T + 1) { it.toDouble() }
        fun lane(k: Int, end: Float, log: Boolean = false, map: (Float) -> Float) = Lane.of(pts, FloatArray(T + 1) { if (it < T) map(v(it, k)) else end }, log)
        s.a.vol = lane(0, 0f) { it }; s.a.bass = lane(1, -26f) { -26 * (1 - it) }; s.a.mid = lane(2, -12f) { -12 * (1 - it) }
        s.a.hp = lane(3, 20 * 35f.pow(v(T - 1, 3)), true) { 20 * 35f.pow(it) }
        s.a.lp = lane(4, 20000 * 0.02f.pow(v(T - 1, 4)), true) { 20000 * 0.02f.pow(it) }
        s.a.echo = lane(5, 70 * v(T - 1, 5)) { 70 * it }; s.a.reverb = lane(6, 85 * v(T - 1, 6)) { 85 * it }
        s.a.gain = lane(7, -96f) { if (it < 0.02f) -96f else max(-96f, 20 * log10(it)) }
        s.b.vol = lane(8, 1f) { it }; s.b.bass = lane(9, 0f) { -26 * (1 - it) }; s.b.mid = lane(10, 0f) { -12 * (1 - it) }
        s.b.hp = lane(11, 20f, true) { 20 * 35f.pow(it) }; s.b.lp = lane(12, 20000f, true) { 20000 * 0.02f.pow(it) }
        s.echoBeats = listOf(0.75, 0.5).random(); s.echoFeedback = 0.5f
        var swapBeat = T / 2
        for (t in 0 until T) if (v(t, 9) * v(t, 8) > v(t, 1) * v(t, 0) * v(t, 7)) { swapBeat = t; break }
        val swap = max(1, swapBeat).toDouble()
        if (hot && !chill && swapBeat >= 4) {
            val len = min(8, swapBeat).toDouble()
            if (Random.nextBoolean()) s.events += MixEvent.SynthFx(Synth.RISER, swap - len, len)
            if (Random.nextBoolean()) s.events += MixEvent.SynthFx(Synth.IMPACT, swap, 4.0)
        }
        TnHistory.add(signature(y))
        fun maxOf(k: Int) = (0 until T).maxOf { v(it, k) }
        val tA = "«$titleA»"; val tB = "«$titleB»"
        val exit = when {
            maxOf(5) > 0.4f -> "Эхо" to "$tA улетает в эхо"; maxOf(6) > 0.45f -> "Растворение" to "$tA растворяется в реверберации"
            maxOf(4) > 0.45f -> "Глухой фильтр" to "$tA глохнет в низкочастотном фильтре"; maxOf(3) > 0.45f -> "Фильтр-уход" to "$tA уходит в высокочастотный фильтр"
            else -> "Плавный микс" to "$tA плавно гаснет"
        }
        val entry = if (v(1, 11) > 0.45f) "$tB раскрывается из высокочастотного фильтра" else if (v(1, 12) > 0.45f) "$tB поднимается из-под глухого фильтра"
            else if (v(2, 8) < 0.2f) "$tB вступает позже, на сильную долю" else "$tB входит и набирает громкость"
        val steps = listOf("Такт 1: $entry", "Доля ${swapBeat + 1}: бас переходит к $tB", "Дальше: ${exit.second}")
        val tempo = if (abs(ratio - 1) < 0.005) "темп совпадает" else if (synced) "подгоню темп $tB на ${"%+.1f".format((ratio - 1) * 100)}%" else "темпы не сводятся — без наложения ритма"
        val script = MixScript(s.total, swap, 0.0).also { n ->
            n.a.vol = s.a.vol; n.a.bass = s.a.bass; n.a.mid = s.a.mid; n.a.hp = s.a.hp; n.a.lp = s.a.lp; n.a.echo = s.a.echo; n.a.reverb = s.a.reverb; n.a.gain = s.a.gain
            n.b.vol = s.b.vol; n.b.bass = s.b.bass; n.b.mid = s.b.mid; n.b.hp = s.b.hp; n.b.lp = s.b.lp
            n.events += s.events; n.echoBeats = s.echoBeats; n.echoFeedback = s.echoFeedback
        }
        return MixPlan(a.firstBeat + a0 * a.beat, b.firstBeat + b0 * b.beat, swap, script.total - swap, synced,
            "TransitionNet · ${exit.first}", "$tempo; нейросеть нарисовала $SAMPLES переходов, выбран лучший", steps, script, null)
    }

    fun styleOf(y: FloatArray): String {
        val T = TransitionNet.T; val K = TransitionNet.OUT
        fun mx(k: Int) = (0 until T).maxOf { y[it * K + k] }
        return when { mx(5) > 0.4f -> "echo"; mx(6) > 0.45f -> "reverb"; mx(4) > 0.45f -> "lowpass"; mx(3) > 0.45f -> "highpass"; else -> "fade" }
    }

    private fun signature(y: FloatArray): FloatArray {
        val T = TransitionNet.T; val K = TransitionNet.OUT
        return FloatArray(K * 4) { i -> val k = i / 4; val q = i % 4; var s = 0f; for (t in q * 8 until (q + 1) * 8) s += y[t * K + k]; s / 8 }
    }

    private fun evaluate(y: FloatArray, c: TransitionNet.Ctx): Double {
        val T = TransitionNet.T; val K = TransitionNet.OUT
        fun g(hp: Float, lp: Float, f: Float): Float { val hz = 20 * 35f.pow(hp); val lz = 20000 * 0.02f.pow(lp); return 1 / (1 + (hz / f).pow(2)) / (1 + (f / lz).pow(2)) }
        fun s3(x: FloatArray, t: Int) = x[t * 3] + x[t * 3 + 1] + x[t * 3 + 2]
        var refA = 0f; for (t in 0 until 4) refA += s3(c.a, t) / 4
        var refB = 0f; for (t in T - 6 until T) refB += s3(c.b, t) / 6
        var pen = 0.0; var acc = 0f
        for (t in 0 until T) {
            val o = t * K
            val gA = y[o] * y[o + 7]; val gB = y[o + 8]
            val lowA = c.a[t * 3] * gA * y[o + 1] * g(y[o + 3], y[o + 4], 80f)
            val midA = c.a[t * 3 + 1] * gA * (0.25f + 0.75f * y[o + 2]) * g(y[o + 3], y[o + 4], 700f)
            val hiA = c.a[t * 3 + 2] * gA * g(y[o + 3], y[o + 4], 5000f)
            val lowB = c.b[t * 3] * gB * y[o + 9] * g(y[o + 11], y[o + 12], 80f)
            val midB = c.b[t * 3 + 1] * gB * (0.25f + 0.75f * y[o + 10]) * g(y[o + 11], y[o + 12], 700f)
            val hiB = c.b[t * 3 + 2] * gB * g(y[o + 11], y[o + 12], 5000f)
            acc = acc * 0.72f + y[o] * (0.7f * y[o + 5] + 0.6f * y[o + 6]) * s3(c.a, t) / 3 * max(0.3f, y[o + 7])
            val totA = lowA + midA + hiA; val totB = lowB + midB + hiB
            val total = totA + totB + acc * 0.35f
            val target = refA + (refB - refA) * t / (T - 1)
            pen += max(0f, min(lowA, lowB) - 0.12f) * 8.0
            pen += max(0f, min(midA, midB) - 0.25f) * (1 + 2 * (1 - c.keyFit)) * 3.0
            pen += max(0f, 0.55f * target - total).pow(2) * 6.0
            pen += max(0f, total - 1.3f * max(target, 0.3f)).pow(2) * 4.0
            pen += min(totA, totB) * (1 - c.synced) * 6.0
        }
        return -pen / T + Random.nextDouble(-0.01, 0.01)
    }
}
