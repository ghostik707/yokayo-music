package com.yokayo.music.audio

import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.tanh
import kotlin.random.Random

/** Стерео-буфер эффекта (чередующиеся L/R, 44.1 кГц). */
class FxBuffer(val data: FloatArray) { val frames get() = data.size / 2 }

/** Синтез переходных эффектов прямо на устройстве: райзер, удар, «вжух» вниз и др. */
object FxSynth {
    const val SR = 44100

    private fun buf(seconds: Double) = FloatArray(max(1, (seconds * SR).toInt()) * 2)
    private fun rnd() = Random.nextFloat() * 2 - 1

    fun riser(seconds: Double): FxBuffer {
        val d = buf(seconds); val n = d.size / 2; val sr = SR.toFloat()
        var lp1 = 0f; var lp2 = 0f; var hp = 0f; var prev = 0f; var phase = 0f
        for (i in 0 until n) {
            val t = i.toFloat() / n
            val cutoff = 300 * 40f.pow(t)
            val a = 1 - exp(-2 * PI.toFloat() * cutoff / sr)
            val noise = rnd()
            lp1 += a * (noise - lp1); lp2 += a * (lp1 - lp2)
            hp = 0.995f * (hp + lp2 - prev); prev = lp2
            phase += 2 * PI.toFloat() * 180 * 8f.pow(t) / sr
            val tone = sin(phase) * 0.12f * t
            val env = t.pow(2.2f) * if (t > 0.97f) (1 - t) / 0.03f else 1f
            val s = (hp * 0.9f + tone) * env
            val pan = 0.5f + 0.35f * sin(t * 20)
            d[i * 2] = s * (1 - pan) * 1.4f; d[i * 2 + 1] = s * pan * 1.4f
        }
        return FxBuffer(d)
    }

    fun impact(): FxBuffer {
        val d = buf(2.2); val n = d.size / 2; val sr = SR.toFloat()
        var phase = 0f; var lp = 0f
        for (i in 0 until n) {
            val t = i / sr
            phase += 2 * PI.toFloat() * (45 + 90 * exp(-t * 18)) / sr
            val boom = sin(phase) * exp(-t * 2.6f)
            val noise = rnd(); lp += 0.25f * (noise - lp)
            val crash = (noise - lp) * exp(-t * 3.5f) * 0.35f
            val s = tanh(boom * 1.3f) * 0.8f + crash
            d[i * 2] = s; d[i * 2 + 1] = s * 0.96f + crash * 0.08f
        }
        return FxBuffer(d)
    }

    fun downlifter(seconds: Double): FxBuffer {
        val d = buf(seconds); val n = d.size / 2; val sr = SR.toFloat()
        var lp = 0f
        for (i in 0 until n) {
            val t = i.toFloat() / n
            val a = 1 - exp(-2 * PI.toFloat() * 9000 * 0.02f.pow(t) / sr)
            lp += a * (rnd() - lp)
            val env = (1 - t).pow(1.8f) * min(1f, t * 40)
            d[i * 2] = lp * env * 0.7f; d[i * 2 + 1] = lp * env * 0.7f * (0.8f + 0.2f * t)
        }
        return FxBuffer(d)
    }

    fun snareRoll(seconds: Double, beat: Double): FxBuffer {
        val d = buf(seconds); val n = d.size / 2
        var t = 0.0
        while (t < seconds) {
            val k = t / seconds
            val step = if (k < 0.4) beat else if (k < 0.7) beat / 2 else if (k < 0.88) beat / 4 else beat / 8
            val start = (t * SR).toInt(); val len = (0.09 * SR).toInt()
            var lp = 0f
            for (j in 0 until len) {
                if (start + j >= n) break
                val e = exp(-j / (0.025f * SR))
                val noise = rnd(); lp += 0.6f * (noise - lp)
                val tone = sin(2 * PI.toFloat() * (190 + 80 * k.toFloat()) * j / SR) * 0.5f
                val v = ((noise - lp) * 0.8f + tone) * e * (0.25f + 0.75f * k.toFloat())
                d[(start + j) * 2] += v; d[(start + j) * 2 + 1] += v * 0.95f
            }
            t += step
        }
        return FxBuffer(d)
    }

    fun subDrop(): FxBuffer {
        val d = buf(1.8); val n = d.size / 2; val sr = SR.toFloat()
        var phase = 0f
        for (i in 0 until n) {
            val t = i / sr
            phase += 2 * PI.toFloat() * (30 + 60 * exp(-t * 2.2f)) / sr
            val v = tanh(sin(phase) * 1.6f) * exp(-t * 1.4f) * min(1f, t * 200)
            d[i * 2] = v; d[i * 2 + 1] = v
        }
        return FxBuffer(d)
    }

    fun crash(): FxBuffer {
        val d = buf(2.4); val n = d.size / 2; val sr = SR.toFloat()
        var lp = 0f
        for (i in 0 until n) {
            val t = i / sr
            val noise = rnd(); lp += 0.3f * (noise - lp)
            val v = (noise - lp) * exp(-t * 1.6f) * 0.55f
            d[i * 2] = v; d[i * 2 + 1] = v * (0.85f + 0.15f * sin(t * 9))
        }
        return FxBuffer(d)
    }

    fun scaled(b: FxBuffer, gain: Float): FxBuffer { for (i in b.data.indices) b.data[i] *= gain; return b }
}

/** Эффекты из звука самого трека: заикание, нарезка, стоп-пластинка, перемотка. */
object DjBuffers {
    /** Кусок трека (сек файла) в формате эффектов: стерео float 44.1 кГц. */
    fun slice(t: PcmTrack, at: Double, seconds: Double): FxBuffer? {
        val ratio = t.sampleRate / FxSynth.SR.toDouble()
        val n = (seconds * FxSynth.SR).toInt()
        val start = at * t.sampleRate
        if (n <= 0 || start < 0 || start + n * ratio >= t.frames) return null
        val d = t.data
        val out = FloatArray(n * 2)
        for (i in 0 until n) {
            val p = start + i * ratio
            val j = p.toInt(); val f = (p - j).toFloat()
            out[i * 2] = (d[j * 2] * (1 - f) + d[j * 2 + 2] * f) / 32768f
            out[i * 2 + 1] = (d[j * 2 + 1] * (1 - f) + d[j * 2 + 3] * f) / 32768f
        }
        return FxBuffer(out)
    }

    fun roll(src: FxBuffer, beat: Double, beats: Double, gain: Float): FxBuffer {
        val sr = FxSynth.SR
        val n = (beats * beat * sr).toInt()
        val out = FloatArray(n * 2)
        val fade = (0.003 * sr).toInt()
        for (c in 0 until 2) {
            var i = 0; var hp = 0f; var prev = 0f
            while (i < n) {
                val k = i.toDouble() / n
                val div = if (k < 0.5) 0.5 else if (k < 0.75) 0.25 else if (k < 0.9) 0.125 else 0.0625
                val len = max(fade * 3, (div * beat * sr).toInt())
                for (j in 0 until len) {
                    if (i + j >= n) break
                    var v = if (j < src.frames) src.data[j * 2 + c] else 0f
                    if (j < fade) v *= j.toFloat() / fade
                    if (j > len - fade) v *= (len - j).toFloat() / fade
                    val t = (i + j).toFloat() / n
                    val a = 0.995f - 0.25f * t
                    hp = a * (hp + v - prev); prev = v
                    out[(i + j) * 2 + c] = (v * (1 - t) + hp * t) * gain * (0.85f + 0.3f * t)
                }
                i += len
            }
        }
        return FxBuffer(out)
    }

    fun gate(src: FxBuffer, beat: Double, gain: Float): FxBuffer {
        val n = src.frames; val period = beat / 2 * FxSynth.SR
        val out = FloatArray(n * 2)
        for (c in 0 until 2) {
            var g = 1f
            for (i in 0 until n) {
                val t = i.toFloat() / n
                val ph = (i % period) / period
                val target = if (ph < 0.5) 1f else 1 - min(1f, t * 1.6f)
                g += (target - g) * 0.02f
                out[i * 2 + c] = src.data[i * 2 + c] * g * gain
            }
        }
        return FxBuffer(out)
    }

    fun tapeStop(src: FxBuffer, seconds: Double, gain: Float): FxBuffer {
        val n = (seconds * FxSynth.SR).toInt()
        val out = FloatArray(n * 2)
        val len = src.frames
        for (c in 0 until 2) {
            var pos = 0.0
            for (i in 0 until n) {
                val t = i.toDouble() / n
                val speed = (1 - t).pow(1.6)
                val i0 = pos.toInt().coerceIn(0, len - 2); val f = (pos - i0).toFloat()
                val v = src.data[i0 * 2 + c] * (1 - f) + src.data[(i0 + 1) * 2 + c] * f
                out[i * 2 + c] = v * gain * min(1f, ((1 - t) * 8).toFloat())
                pos += speed
            }
        }
        return FxBuffer(out)
    }

    fun backspin(src: FxBuffer, seconds: Double, gain: Float): FxBuffer {
        val n = (seconds * FxSynth.SR).toInt()
        val out = FloatArray(n * 2)
        val len = src.frames
        for (c in 0 until 2) {
            var pos = (len - 1).toDouble()
            for (i in 0 until n) {
                val t = i.toDouble() / n
                val speed = 1 + 3.5 * t * t
                val i0 = pos.toInt().coerceIn(0, len - 2); val f = (pos - i0).toFloat()
                val v = src.data[i0 * 2 + c] * (1 - f) + src.data[(i0 + 1) * 2 + c] * f
                val env = min(1.0, t * 30).toFloat() * (if (t > 0.55) max(0.0, (1 - t) / 0.45) else 1.0).toFloat()
                out[i * 2 + c] = v * env * gain
                pos -= speed
                if (pos < 1) pos = (len - 1).toDouble()
            }
        }
        return FxBuffer(out)
    }
}
