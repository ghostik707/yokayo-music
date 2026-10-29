package com.yokayo.music.audio

import android.content.Context
import org.json.JSONArray
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

/** Кривая значения по долям: точки и линейная (для частот — логарифмическая) интерполяция. */
class Lane(v: Float, private val log: Boolean = false) {
    private val pts = mutableListOf(0.0)
    private val vals = mutableListOf(v)

    fun at(x: Double): Float {
        val i = pts.indexOfFirst { it > x }
        if (i == -1) return vals.last()
        if (i == 0) return vals[0]
        val t = ((x - pts[i - 1]) / max(1e-6, pts[i] - pts[i - 1])).toFloat()
        val a = vals[i - 1]; val b = vals[i]
        return if (log) a * (b / a).pow(t) else a + (b - a) * t
    }

    /** От текущего значения к `v` между долями; всё, что было после `start`, заменяется. */
    fun ramp(v: Float, start: Double, end: Double, shape: Double = 1.0) {
        val v0 = at(start)
        while (pts.size > 1 && pts.last() > start) { pts.removeAt(pts.lastIndex); vals.removeAt(vals.lastIndex) }
        if (pts.last() < start) { pts += start; vals += v0 } else vals[vals.lastIndex] = v0
        val steps = if (shape == 1.0) 1 else 8
        for (k in 1..steps) {
            val t = k.toDouble() / steps
            pts += start + (end - start) * t
            val f = t.pow(shape).toFloat()
            vals += if (log) v0 * (v / v0).pow(f) else v0 + (v - v0) * f
        }
    }
}

class DeckLanes {
    var vol = Lane(1f); var gain = Lane(0f); var bass = Lane(0f); var mid = Lane(0f)
    var hp = Lane(20f, true); var lp = Lane(20000f, true); var echo = Lane(0f); var reverb = Lane(0f)
}

enum class Synth { RISER, SNARE_ROLL, IMPACT, CRASH, DOWNLIFTER, SUB_DROP }

sealed class MixEvent(val at: Double, val beats: Double) {
    class SynthFx(val kind: Synth, at: Double, beats: Double) : MixEvent(at, beats)
    class Roll(at: Double, beats: Double) : MixEvent(at, beats)
    class Gate(at: Double, beats: Double) : MixEvent(at, beats)
    class Brake(at: Double, beats: Double) : MixEvent(at, beats)
    class Spin(at: Double, beats: Double) : MixEvent(at, beats)
}

/** Сценарий перехода: кривые обеих дек по долям A и разовые эффекты. */
class MixScript(val total: Double, val swap: Double, val bEnter: Double) {
    val a = DeckLanes(); val b = DeckLanes()
    val events = mutableListOf<MixEvent>()
    var echoBeats = 0.75
    var echoFeedback = 0.5f
    val blend get() = bEnter < swap
}

/** План перехода. */
class MixPlan(
    val aStart: Double, val bStart: Double, val swapBeats: Double, val tailBeats: Double, val synced: Boolean,
    val headline: String, val reason: String, val steps: List<String>,
    val script: MixScript, val recipe: MixComposer.Recipe?,
) {
    val totalBeats get() = swapBeats + tailBeats
    val swapAt get() = swapBeats / totalBeats
}

/** ИИ-композитор переходов (порт с iPhone). Каждый переход собирается заново из приёмов,
 *  сотни вариантов «проигрываются в уме» по энергии и басу обоих треков, выбирается один из лучших. */
object MixComposer {
    enum class Entry { FADE, FILTER_OPEN, LOWPASS_RISE, CUT }
    enum class Exit { BASS_KILL, LOWPASS_DOWN, ECHO, REVERB_WASH, BRAKE, BACKSPIN, ROLL, GATE, FADE }
    enum class Swap { BASS_SWAP, GRADUAL_BASS, HARD_CUT, SILENCE_DROP }
    enum class FX { NONE, RISER, SNARE_ROLL, RISER_IMPACT, CRASH, DOWNLIFTER, SUB_DROP }

    data class Recipe(
        val overlapBars: Int, val preBars: Int, val tailBars: Int, val entry: Entry, val exit: Exit, val swap: Swap, val fx: FX,
        val midCut: Boolean, val shape: Double, val bFromDrop: Boolean, val hot: Boolean, val chill: Boolean,
    ) {
        val buffered get() = exit in setOf(Exit.BRAKE, Exit.BACKSPIN, Exit.ROLL, Exit.GATE)
        val ends get() = swap == Swap.HARD_CUT || swap == Swap.SILENCE_DROP
        val overlapBucket get() = listOf(0, 2, 4, 8, 16).indexOf(overlapBars).takeIf { it >= 0 } ?: 2
        val signature get() = listOf(entry.ordinal, exit.ordinal, swap.ordinal, fx.ordinal, overlapBucket)
    }

    private class Ctx(val a: TrackAnalysis, val b: TrackAnalysis, val synced: Boolean, val keysFit: Boolean, val hot: Boolean,
                      val chill: Boolean, val hiphop: Boolean, val longBlend: Boolean, val gridA: Boolean, val intro: Int)

    const val CANDIDATES = 320

    fun tempoRatio(bpmA: Double, b: TrackAnalysis): Pair<Double, Double> {
        val mult = listOf(1.0, 2.0, 0.5).minBy { abs(bpmA / (b.bpm * it) - 1) }
        return bpmA / (b.bpm * mult) to mult
    }

    fun compatibility(a: TrackAnalysis, b: TrackAnalysis): Double {
        val (ratio, _) = tempoRatio(a.bpm, b)
        val dev = abs(ratio - 1)
        val tempo = if (dev <= 0.08) 1 - dev / 0.08 * 0.6 else max(0.0, 0.3 - dev)
        val key = when (TrackAnalysis.keyDistance(a, b)) { 0 -> 1.0; 1 -> 0.85; 2 -> 0.5; null -> 0.6; else -> 0.25 }
        return tempo * 0.55 + key * 0.3 + min(a.confidence, b.confidence) * 0.15
    }

    fun compose(a: TrackAnalysis, b: TrackAnalysis, rateA: Double, titleA: String, titleB: String, now: Double, start: Double? = null): MixPlan {
        val bpmA = a.bpm * rateA
        val (ratio, _) = tempoRatio(bpmA, b)
        val gridOK = a.confidence >= 0.5 && b.confidence >= 0.5
        val keyDist = TrackAnalysis.keyDistance(a, b)
        val hot = b.dropJump >= 1.5f
        val outroE = a.meanBarEnergy(a.outroStartBar - 4, a.outroStartBar)
        val introE = b.meanBarEnergy(0, max(1, b.introEndBar))
        val c = Ctx(a, b, abs(ratio - 1) <= 0.08 && gridOK, (keyDist ?: 1) <= 1, hot,
            !hot && (bpmA < 100 || (outroE < 0.45f && introE < 0.45f)), bpmA < 105 && b.bpm < 105,
            b.introEndBar >= 8 && a.outroFound, a.confidence >= 0.4, b.introEndBar)
        val history = MixBrain.history
        val scored = (0 until CANDIDATES).map { val r = random(c, start != null); r to score(r, c, history) }.sortedByDescending { it.second }
        val top = scored.take(5)
        val weights = top.map { exp((it.second - top[0].second) / 0.15) }
        var pick = Random.nextDouble() * weights.sum()
        var chosen = top[0].first
        for ((i, w) in weights.withIndex()) { pick -= w; if (pick <= 0) { chosen = top[i].first; break } }
        return plan(chosen, c, bpmA, ratio, titleA, titleB, now, start)
    }

    /** Простой кроссфейд без DJ-режима: последние `seconds` секунд. */
    fun crossfade(seconds: Double, aStart: Double, bStart: Double): MixPlan {
        val s = MixScript(seconds, seconds * 0.5, 0.0)
        s.a.vol.ramp(0f, 0.0, seconds, 0.7)
        s.b.vol = Lane(0f); s.b.vol.ramp(1f, 0.0, seconds, 1.4)
        return MixPlan(aStart, bStart, seconds * 0.5, seconds * 0.5, false, "Кроссфейд ${seconds.toInt()} с", "плавная смена треков", emptyList(), s, null)
    }

    private fun <T> List<T>.rnd() = this[Random.nextInt(size)]

    private fun random(c: Ctx, urgent: Boolean): Recipe {
        val blend = c.synced && Random.nextDouble() < 0.72
        val fx = FX.entries.rnd()
        var r = Recipe(0, listOf(1, 2).rnd(), listOf(1, 2, 4).rnd(), Entry.CUT, Exit.ECHO, Swap.HARD_CUT, fx, Random.nextBoolean(),
            listOf(0.6, 1.0, 1.7).rnd(), Random.nextBoolean(), c.hot, c.chill)
        if (blend) {
            val exit = Exit.entries.filter { c.gridA || it !in setOf(Exit.ROLL, Exit.GATE) }.rnd()
            r = r.copy(overlapBars = (if (urgent) listOf(2, 4) else listOf(2, 4, 8, 16)).rnd(),
                entry = listOf(Entry.FADE, Entry.FILTER_OPEN, Entry.LOWPASS_RISE).rnd(), exit = exit)
            r = r.copy(swap = if (r.buffered) listOf(Swap.HARD_CUT, Swap.SILENCE_DROP).rnd() else Swap.entries.rnd())
        } else {
            r = r.copy(exit = listOf(Exit.ECHO, Exit.REVERB_WASH, Exit.BRAKE, Exit.BACKSPIN, Exit.LOWPASS_DOWN, Exit.FADE, Exit.ROLL, Exit.GATE)
                .filter { c.gridA || it !in setOf(Exit.ROLL, Exit.GATE) }.rnd(),
                swap = listOf(Swap.HARD_CUT, Swap.SILENCE_DROP).rnd(), preBars = if (urgent) 1 else r.preBars)
        }
        return r
    }

    fun script(r: Recipe): MixScript {
        val S = (if (r.overlapBars > 0) r.overlapBars * 4 else r.preBars * 4).toDouble()
        val washy = r.exit == Exit.ECHO || r.exit == Exit.REVERB_WASH
        val tail = if (r.ends) (if (washy) 8.0 else 2.0) else (max(r.tailBars, if (washy) 2 else 1) * 4).toDouble()
        val T = S + tail
        val s = MixScript(T, S, if (r.overlapBars > 0) 0.0 else S)
        s.echoBeats = listOf(0.75, 0.5, 1.0).rnd()
        s.echoFeedback = 0.40f + Random.nextFloat() * 0.22f
        val sh = r.shape
        when (r.entry) {
            Entry.FADE -> { s.b.vol = Lane(0f); s.b.vol.ramp(1f, 0.0, min(S, 16.0), sh); s.b.bass = Lane(-26f) }
            Entry.FILTER_OPEN -> { s.b.vol = Lane(0f); s.b.vol.ramp(1f, 0.0, min(S, 8.0)); s.b.hp = Lane(1400f, true); s.b.hp.ramp(20f, 0.0, S, sh); s.b.bass = Lane(-26f) }
            Entry.LOWPASS_RISE -> { s.b.vol = Lane(0f); s.b.vol.ramp(1f, 0.0, min(S, 8.0)); s.b.lp = Lane(260f, true); s.b.lp.ramp(20000f, 0.0, S, sh); s.b.bass = Lane(-26f) }
            Entry.CUT -> {}
        }
        if (r.overlapBars > 0 && r.midCut) s.a.mid.ramp(-9f, S * 0.5, S)
        val cutAt = if (r.swap == Swap.SILENCE_DROP) S - 1 else S
        val fxLen = when (r.exit) { Exit.ROLL -> min(4.0, cutAt); Exit.GATE -> min(8.0, cutAt); Exit.BRAKE -> 2.0; Exit.BACKSPIN -> min(4.0, cutAt); else -> 0.0 }
        val goneAt = if (r.buffered) cutAt - fxLen else cutAt
        when (r.exit) {
            Exit.BASS_KILL -> if (r.ends) s.a.hp.ramp(420f, max(0.0, S - 8), cutAt, sh) else { s.a.hp.ramp(750f, S, T, sh); s.a.vol.ramp(0f, S, T, 1.6) }
            Exit.LOWPASS_DOWN -> { s.a.lp.ramp(420f, max(0.0, if (r.ends) cutAt - 8 else S * 0.4), if (r.ends) cutAt else S, sh); if (!r.ends) s.a.vol.ramp(0f, S, T) }
            Exit.ECHO -> {
                val e0 = if (r.ends) max(0.0, cutAt - 4) else S + (T - S) * 0.25
                s.a.echo.ramp(65f, e0, if (r.ends) cutAt else S + (T - S) * 0.6)
                s.a.hp.ramp(260f, e0, if (r.ends) cutAt else T)
                if (!r.ends) s.a.gain.ramp(-96f, S + (T - S) * 0.6, S + (T - S) * 0.7)
            }
            Exit.REVERB_WASH -> {
                val w0 = if (r.ends) max(0.0, cutAt - 4) else S
                s.a.reverb.ramp(85f, w0, if (r.ends) cutAt else S + (T - S) * 0.5)
                if (!r.ends) s.a.gain.ramp(-96f, S + (T - S) * 0.5, S + (T - S) * 0.6)
            }
            Exit.FADE -> if (r.ends) s.a.vol.ramp(0f, max(0.0, cutAt - 8), cutAt, sh) else s.a.vol.ramp(0f, S - min(S, 4.0), T, sh)
            Exit.BRAKE -> s.events += MixEvent.Brake(goneAt, fxLen)
            Exit.BACKSPIN -> s.events += MixEvent.Spin(goneAt, fxLen)
            Exit.ROLL -> s.events += MixEvent.Roll(goneAt, fxLen)
            Exit.GATE -> s.events += MixEvent.Gate(goneAt, fxLen)
        }
        when (r.swap) {
            Swap.BASS_SWAP -> { s.b.bass.ramp(0f, S, S + 1); s.a.bass.ramp(-26f, S, S + 1) }
            Swap.GRADUAL_BASS -> { val h = min(4.0, S / 2); s.b.bass.ramp(0f, S - h, S + h); s.a.bass.ramp(-26f, S - h, S + h) }
            Swap.HARD_CUT, Swap.SILENCE_DROP -> {
                if (goneAt > 0) s.a.gain.ramp(-96f, goneAt - 0.06, goneAt) else s.a.gain = Lane(-96f)
                s.b.bass.ramp(0f, S - 0.05, S)
                if (r.swap == Swap.SILENCE_DROP && r.overlapBars > 0) { s.b.gain.ramp(-60f, cutAt - 0.06, cutAt); s.b.gain.ramp(0f, S - 0.03, S) }
            }
        }
        if (r.entry != Entry.CUT) s.b.vol.ramp(1f, max(0.0, S - 0.5), S)
        val riserLen = min(if (S >= 8) 8.0 else 4.0, max(2.0, S))
        val long = if (S >= 16) 2 else 1
        when (r.fx) {
            FX.NONE -> {}
            FX.RISER -> s.events += MixEvent.SynthFx(Synth.RISER, S - riserLen * long, riserLen * long)
            FX.SNARE_ROLL -> s.events += MixEvent.SynthFx(Synth.SNARE_ROLL, S - riserLen, riserLen)
            FX.RISER_IMPACT -> { s.events += MixEvent.SynthFx(Synth.RISER, S - riserLen, riserLen); s.events += MixEvent.SynthFx(Synth.IMPACT, S, 4.0) }
            FX.CRASH -> s.events += MixEvent.SynthFx(Synth.CRASH, S, 4.0)
            FX.DOWNLIFTER -> s.events += MixEvent.SynthFx(Synth.DOWNLIFTER, S, 8.0)
            FX.SUB_DROP -> s.events += MixEvent.SynthFx(Synth.SUB_DROP, S, 4.0)
        }
        return s
    }

    private fun dbLin(db: Float) = if (db <= -90) 0f else 10f.pow(db / 20)

    private fun score(r: Recipe, c: Ctx, history: List<List<Int>>): Double {
        val s = script(r)
        val T = s.total; val S = s.swap
        val aBar0 = max(0, c.a.outroStartBar - (S / 4).toInt())
        val bBar0 = if (r.overlapBars > 0) max(0, c.intro - r.overlapBars) else if (r.bFromDrop && c.intro > 0) c.intro else 0
        fun bar(arr: FloatArray, i: Int) = if (arr.isEmpty()) 0.6f else arr[i.coerceIn(0, arr.size - 1)]
        val aRef = c.a.meanBarEnergy(aBar0 - 4, aBar0); val bRef = c.b.meanBarEnergy(bBar0 + (T / 4).toInt(), bBar0 + (T / 4).toInt() + 8)
        var clash = 0.0; var hole = 0.0; var loud = 0.0; var voice = 0.0; var tailE = 0f
        val span = s.events.firstOrNull { it !is MixEvent.SynthFx }?.let { it.at..(it.at + it.beats) }
        var x = 0.0
        while (x < T) {
            val ia = aBar0 + (x / 4).toInt()
            val aE = bar(c.a.barEnergy, ia); val aL = bar(c.a.barLow, ia)
            val gA = s.a.vol.at(x) * dbLin(s.a.gain.at(x))
            val lpA = s.a.lp.at(x)
            var aFull = aE * gA * (if (lpA < 2000) lpA / 2000 else 1f)
            var aLow = aL * gA * dbLin(s.a.bass.at(x)) * min(1f, 80 / s.a.hp.at(x))
            if (span != null && x in span) { aFull = aE * 0.8f; aLow = aL * 0.5f }
            tailE = max(tailE * 0.82f, aE * (s.a.echo.at(x) + s.a.reverb.at(x)) / 100)
            var bFull = 0f; var bLow = 0f
            if (x >= s.bEnter) {
                val ib = bBar0 + ((x - s.bEnter) / 4).toInt()
                val gB = s.b.vol.at(x) * dbLin(s.b.gain.at(x))
                val lpB = s.b.lp.at(x)
                bFull = bar(c.b.barEnergy, ib) * gB * (if (lpB < 2000) lpB / 2000 else 1f) * min(1f, 800 / max(800f, s.b.hp.at(x)) + 0.3f)
                bLow = bar(c.b.barLow, ib) * gB * dbLin(s.b.bass.at(x)) * min(1f, 80 / s.b.hp.at(x))
            }
            clash += max(0f, min(aLow, bLow) - 0.22f)
            val L = (aFull + bFull + tailE * 0.3f).toDouble()
            val target = (aRef + (bRef - aRef) * (x / T)).toDouble()
            val silent = r.swap == Swap.SILENCE_DROP && x >= S - 1 && x < S
            if (!silent) hole += max(0.0, 0.5 * target - L)
            loud += max(0.0, L - 1.3 * max(target, 0.35))
            voice += max(0f, min(aFull * dbLin(s.a.mid.at(x)), bFull) - 0.3f)
            x += 0.5
        }
        val n = T * 2
        var sc = -(clash / n) * 6 - (hole / n) * 5 - (loud / n) * 3 - (voice / n) * (if (c.keysFit) 1.5 else 4.0)
        val impacty = setOf(FX.RISER_IMPACT, FX.SUB_DROP, FX.CRASH)
        val trick = setOf(Exit.ROLL, Exit.GATE, Exit.BRAKE, Exit.BACKSPIN)
        val smooth = setOf(Exit.REVERB_WASH, Exit.FADE, Exit.ECHO, Exit.LOWPASS_DOWN)
        if (c.hot) {
            if (r.fx in setOf(FX.RISER, FX.SNARE_ROLL, FX.RISER_IMPACT)) sc += 0.5
            if (r.swap == Swap.SILENCE_DROP) sc += 0.2
            if (r.overlapBars == 0 && r.bFromDrop) sc += 0.3
        }
        if (c.chill) {
            if (r.fx in impacty || r.fx == FX.SNARE_ROLL) sc -= 0.7
            if (r.exit in trick) sc -= 0.6
            if (r.exit in smooth) sc += 0.35
            if (r.overlapBars >= 8) sc += 0.35
        }
        if (c.hiphop) {
            if (r.exit == Exit.BACKSPIN || r.exit == Exit.BRAKE) sc += 0.3
            if (r.fx == FX.SUB_DROP) sc += 0.25
            if (r.overlapBars >= 8) sc -= 0.3
        }
        if (c.longBlend && r.overlapBars >= 8) sc += 0.45
        if (!c.longBlend && r.overlapBars >= 8) sc -= 0.5
        if (!c.keysFit && r.overlapBars >= 8) sc -= 0.6
        if (r.overlapBars > max(4, c.intro)) sc -= 0.12 * (r.overlapBars - max(4, c.intro))
        history.reversed().forEachIndexed { i, h ->
            val same = h.zip(r.signature).count { it.first == it.second }
            sc -= 1.3 * (same / 5.0).pow(2) * 0.8.pow(i)
            if (i == 0 && h.size > 1 && h[1] == r.exit.ordinal) sc -= 0.5
        }
        sc += 1.4 * (MixBrain.like(r) - 0.5)
        sc += Random.nextDouble(-0.12, 0.12)
        return sc
    }

    private fun plan(r: Recipe, c: Ctx, bpmA: Double, ratio: Double, titleA: String, titleB: String, now: Double, start: Double?): MixPlan {
        val a = c.a; val b = c.b
        val sc = script(r)
        val sBars = (sc.swap / 4).toInt()
        val bStart = if (r.overlapBars > 0) {
            val bStartBar = if (c.intro >= r.overlapBars) c.intro - r.overlapBars else 0
            if (bStartBar == 0 && c.intro == 0) b.mixIn else b.time(bStartBar)
        } else if (r.bFromDrop && c.intro in 1..32) b.time(c.intro) else b.mixIn
        val aStart = start ?: run {
            val lastBar = a.lastSoundBar
            val tailBars = ceil((sc.total - sc.swap) / 4).toInt()
            var swapBar = a.outroStartBar
            if (swapBar + tailBars > lastBar) swapBar = lastBar - tailBars
            swapBar = max(swapBar, a.bar(now) + 2 + sBars)
            a.time(max(0, swapBar - sBars))
        }
        val tA = "«$titleA»"; val tB = "«$titleB»"
        val entryText = when (r.entry) {
            Entry.FADE -> "$tB входит без баса и набирает громкость"; Entry.FILTER_OPEN -> "$tB раскрывается из высокочастотного фильтра"
            Entry.LOWPASS_RISE -> "$tB поднимается из-под глухого фильтра"; Entry.CUT -> ""
        }
        val exitText = when (r.exit) {
            Exit.BASS_KILL -> "$tA теряет низ и уходит в фильтр"; Exit.LOWPASS_DOWN -> "$tA глохнет в низкочастотном фильтре"
            Exit.ECHO -> "$tA улетает в эхо"; Exit.REVERB_WASH -> "$tA растворяется в реверберации"; Exit.BRAKE -> "стоп-пластинка на $tA"
            Exit.BACKSPIN -> "перемотка $tA назад"; Exit.ROLL -> "бит $tA заикается всё быстрее"; Exit.GATE -> "$tA режется на восьмые"
            Exit.FADE -> "$tA плавно гаснет"
        }
        val swapText = when (r.swap) {
            Swap.BASS_SWAP -> "обмен басами"; Swap.GRADUAL_BASS -> "бас плавно переходит к $tB"
            Swap.HARD_CUT -> "резкая смена на сильную долю"; Swap.SILENCE_DROP -> "доля тишины — и дроп $tB"
        }
        val fxText = when (r.fx) {
            FX.NONE -> null; FX.RISER -> "райзер"; FX.SNARE_ROLL -> "снейр-ролл"; FX.RISER_IMPACT -> "райзер и удар"
            FX.CRASH -> "тарелка на смене"; FX.DOWNLIFTER -> "«выдох» после смены"; FX.SUB_DROP -> "саб-дроп"
        }
        val exitTitle = when (r.exit) {
            Exit.BASS_KILL -> "Фильтр-уход"; Exit.LOWPASS_DOWN -> "Глухой фильтр"; Exit.ECHO -> "Эхо"; Exit.REVERB_WASH -> "Растворение"
            Exit.BRAKE -> "Стоп-пластинка"; Exit.BACKSPIN -> "Перемотка"; Exit.ROLL -> "Бит-ролл"; Exit.GATE -> "Нарезка"; Exit.FADE -> "Плавный микс"
        }
        val fxs = fxText?.let { " · $it" } ?: ""
        val steps = mutableListOf<String>()
        if (r.overlapBars > 0) {
            steps += "Такт 1: $entryText" + if (r.midCut) ", голос $tA отходит назад" else ""
            if (r.buffered) steps += "Последние доли перед сменой: $exitText"
            steps += "Такт ${sBars + 1}: $swapText$fxs"
            if (!r.buffered) steps += "Дальше: $exitText"
        } else {
            steps += (if (sBars > 1) "Такты 1–$sBars" else "Такт 1") + ": $exitText"
            steps += "Такт ${sBars + 1}: $swapText — $tB ${if (bStart > b.mixIn + 1) "сразу с дропа" else "с начала"}$fxs"
        }
        val tempoText = if (abs(ratio - 1) < 0.005) "темп совпадает (${bpmA.toInt()} BPM)"
            else if (c.synced) "подгоню темп $tB на ${"%+.1f".format((ratio - 1) * 100)}%"
            else "темпы ${bpmA.toInt()}→${b.bpm.toInt()} не сводятся — смена без наложения"
        val keyText = if (a.camelot != null && b.camelot != null) "; ${a.camelot}→${b.camelot} ${if (c.keysFit) "гармонично" else "конфликтуют"}" else ""
        val mood = if (c.hot) "; у $tB мощный дроп" else if (c.chill) "; спокойная пара" else ""
        return MixPlan(aStart, bStart, sc.swap, sc.total - sc.swap, c.synced,
            "$exitTitle · " + if (r.overlapBars > 0) "${r.overlapBars} ${if (r.overlapBars < 5) "такта" else "тактов"}" else "на сильную долю",
            "$tempoText$keyText$mood; собран из $CANDIDATES вариантов", steps, sc, r)
    }
}

/** Вкус слушателя: логистическая модель, учится на скипах и 👍/👎 прямо на телефоне. */
object MixBrain {
    private const val DIM = 1 + 4 + 9 + 4 + 7 + 5 + 1 + 9 + 7
    private lateinit var p: android.content.SharedPreferences
    var w = DoubleArray(DIM); private set
    var history = listOf<List<Int>>(); private set
    private var pending: Pair<MixComposer.Recipe, Long>? = null

    fun init(ctx: Context) {
        if (::p.isInitialized) return
        p = ctx.getSharedPreferences("mixbrain", Context.MODE_PRIVATE)
        p.getString("w", null)?.split(",")?.mapNotNull { it.toDoubleOrNull() }?.takeIf { it.size == DIM }?.let { w = it.toDoubleArray() }
        history = runCatching { JSONArray(p.getString("h", "[]")).let { a -> (0 until a.length()).map { i -> a.getJSONArray(i).let { r -> (0 until r.length()).map { r.getInt(it) } } } } }.getOrDefault(emptyList())
    }

    private fun features(r: MixComposer.Recipe): DoubleArray {
        val f = DoubleArray(DIM); var o = 0
        fun one(i: Int, n: Int, v: Double = 1.0) { f[o + i] = v; o += n }
        one(0, 1); one(r.entry.ordinal, 4); one(r.exit.ordinal, 9); one(r.swap.ordinal, 4); one(r.fx.ordinal, 7)
        one(r.overlapBucket, 5); one(0, 1, if (r.midCut) 1.0 else 0.0)
        one(r.exit.ordinal, 9, if (r.chill) 1.0 else 0.0); one(r.fx.ordinal, 7, if (r.hot) 1.0 else 0.0)
        return f
    }

    fun like(r: MixComposer.Recipe): Double { val f = features(r); var z = 0.0; for (i in f.indices) z += w[i] * f[i]; return 1 / (1 + exp(-z)) }

    fun learn(r: MixComposer.Recipe, good: Boolean, strength: Double = 1.0) {
        val f = features(r); val err = (if (good) 1.0 else 0.0) - like(r)
        val nw = w.copyOf(); for (i in nw.indices) nw[i] += 0.35 * strength * err * f[i] - 0.002 * nw[i]
        w = nw
        if (::p.isInitialized) p.edit().putString("w", w.joinToString(",")).apply()
    }

    fun began(r: MixComposer.Recipe) {
        history = (history + listOf(r.signature)).takeLast(8)
        if (::p.isInitialized) p.edit().putString("h", JSONArray(history.map { JSONArray(it) }).toString()).apply()
    }

    fun finished(r: MixComposer.Recipe) { pending = r to System.currentTimeMillis() }

    fun userSkipped() {
        val (r, at) = pending ?: return
        pending = null
        if (System.currentTimeMillis() - at < 20_000) learn(r, false)
    }

    fun tick() {
        val (r, at) = pending ?: return
        if (System.currentTimeMillis() - at > 45_000) { pending = null; learn(r, true, 0.5) }
    }
}
