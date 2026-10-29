package com.yokayo.music.audio

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sinh
import kotlin.math.ln
import kotlin.math.sqrt

/** Быстрое преобразование Фурье для действительного сигнала (радикс-2, на месте). */
class Fft(val n: Int) {
    private val bits = Integer.numberOfTrailingZeros(n)
    private val rev = IntArray(n) { Integer.reverse(it) ushr (32 - bits) }
    private val cosT = FloatArray(n / 2) { cos(2 * PI * it / n).toFloat() }
    private val sinT = FloatArray(n / 2) { -sin(2 * PI * it / n).toFloat() }
    private val re = FloatArray(n)
    private val im = FloatArray(n)

    /** Модули спектра |X_k| для k = 0 until n/2. */
    fun magnitudes(input: FloatArray, offset: Int, window: FloatArray, out: FloatArray) {
        for (i in 0 until n) { re[rev[i]] = input[offset + i] * window[i]; im[rev[i]] = 0f }
        var size = 2
        while (size <= n) {
            val half = size / 2
            val step = n / size
            var start = 0
            while (start < n) {
                var k = 0
                for (j in start until start + half) {
                    val c = cosT[k]; val s = sinT[k]
                    val l = j + half
                    val tr = re[l] * c - im[l] * s
                    val ti = re[l] * s + im[l] * c
                    re[l] = re[j] - tr; im[l] = im[j] - ti
                    re[j] += tr; im[j] += ti
                    k += step
                }
                start += size
            }
            size *= 2
        }
        for (k in 0 until n / 2) out[k] = sqrt(re[k] * re[k] + im[k] * im[k])
    }

    companion object {
        fun hann(n: Int) = FloatArray(n) { (0.5 - 0.5 * cos(2 * PI * it / n)).toFloat() }
    }
}

/** Биквадратный фильтр (RBJ), стерео. */
class Biquad {
    private var b0 = 1.0; private var b1 = 0.0; private var b2 = 0.0; private var a1 = 0.0; private var a2 = 0.0
    private var x1l = 0.0; private var x2l = 0.0; private var y1l = 0.0; private var y2l = 0.0
    private var x1r = 0.0; private var x2r = 0.0; private var y1r = 0.0; private var y2r = 0.0
    var bypass = true
        private set
    private var key = Double.NaN

    private fun set(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        this.b0 = b0 / a0; this.b1 = b1 / a0; this.b2 = b2 / a0; this.a1 = a1 / a0; this.a2 = a2 / a0
    }

    fun off() { bypass = true; key = Double.NaN }

    /** type: 0 lowShelf, 1 highShelf, 2 peaking, 3 highPass, 4 lowPass. */
    fun configure(type: Int, sr: Double, freq: Double, gainDb: Double = 0.0, q: Double = 0.707) {
        val k = type * 1e9 + freq * 1e3 + gainDb * 7.0 + q
        if (k == key && !bypass) return
        key = k; bypass = false
        val f = freq.coerceIn(10.0, sr * 0.45)
        val w = 2 * PI * f / sr
        val cw = cos(w); val sw = sin(w)
        val a = 10.0.pow(gainDb / 40)
        when (type) {
            0, 1 -> {
                val alpha = sw / 2 * sqrt((a + 1 / a) * (1 / 0.9 - 1) + 2)
                val sa = 2 * sqrt(a) * alpha
                if (type == 0) set(a * ((a + 1) - (a - 1) * cw + sa), 2 * a * ((a - 1) - (a + 1) * cw), a * ((a + 1) - (a - 1) * cw - sa),
                    (a + 1) + (a - 1) * cw + sa, -2 * ((a - 1) + (a + 1) * cw), (a + 1) + (a - 1) * cw - sa)
                else set(a * ((a + 1) + (a - 1) * cw + sa), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - sa),
                    (a + 1) - (a - 1) * cw + sa, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - sa)
            }
            2 -> {
                val alpha = sw * sinh(ln(2.0) / 2 * q * w / sw)
                set(1 + alpha * a, -2 * cw, 1 - alpha * a, 1 + alpha / a, -2 * cw, 1 - alpha / a)
            }
            3 -> { val alpha = sw / (2 * q); set((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + alpha, -2 * cw, 1 - alpha) }
            else -> { val alpha = sw / (2 * q); set((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + alpha, -2 * cw, 1 - alpha) }
        }
    }

    fun process(buf: FloatArray, frames: Int) {
        if (bypass) return
        var i = 0
        while (i < frames * 2) {
            val xl = buf[i].toDouble()
            val yl = b0 * xl + b1 * x1l + b2 * x2l - a1 * y1l - a2 * y2l
            x2l = x1l; x1l = xl; y2l = y1l; y1l = yl
            buf[i] = yl.toFloat()
            val xr = buf[i + 1].toDouble()
            val yr = b0 * xr + b1 * x1r + b2 * x2r - a1 * y1r - a2 * y2r
            x2r = x1r; x1r = xr; y2r = y1r; y1r = yr
            buf[i + 1] = yr.toFloat()
            i += 2
        }
        // защита от денормалов и «застревания» после резких скачков
        if (y1l.isNaN() || y1r.isNaN()) { x1l = 0.0; x2l = 0.0; y1l = 0.0; y2l = 0.0; x1r = 0.0; x2r = 0.0; y1r = 0.0; y2r = 0.0 }
    }

    fun reset() { x1l = 0.0; x2l = 0.0; y1l = 0.0; y2l = 0.0; x1r = 0.0; x2r = 0.0; y1r = 0.0; y2r = 0.0 }
}

/** Эхо: линия задержки с обратной связью и мягким срезом верхов. */
class Echo(private val sr: Int) {
    private val l = FloatArray(sr * 2 + 8)
    private val r = FloatArray(sr * 2 + 8)
    private var w = 0
    private var lpL = 0f; private var lpR = 0f

    /** wet 0…1 смешивается поверх сухого сигнала, time — сек, feedback 0…1. */
    fun process(buf: FloatArray, frames: Int, wet: Float, time: Double, feedback: Float) {
        if (wet <= 0.001f && feedback <= 0f) return
        val d = (time * sr).toInt().coerceIn(1, l.size - 2)
        var i = 0
        for (f in 0 until frames) {
            val rp = (w - d + l.size) % l.size
            val dl = l[rp]; val dr = r[rp]
            lpL += 0.35f * (dl - lpL); lpR += 0.35f * (dr - lpR)
            l[w] = buf[i] + lpL * feedback
            r[w] = buf[i + 1] + lpR * feedback
            buf[i] = buf[i] * (1 - wet * 0.5f) + dl * wet
            buf[i + 1] = buf[i + 1] * (1 - wet * 0.5f) + dr * wet
            w = (w + 1) % l.size
            i += 2
        }
    }

    fun clear() { l.fill(0f); r.fill(0f); lpL = 0f; lpR = 0f }
}

/** Реверберация (упрощённый Freeverb): 4 гребёнки + 2 всепропускающих на канал. */
class Reverb(sr: Int) {
    private val combLens = intArrayOf(1116, 1188, 1277, 1356).map { it * sr / 44100 }
    private val apLens = intArrayOf(556, 441).map { it * sr / 44100 }
    private val combsL = combLens.map { FloatArray(it) }; private val combsR = combLens.map { FloatArray(it + 23) }
    private val apsL = apLens.map { FloatArray(it) }; private val apsR = apLens.map { FloatArray(it + 23) }
    private val cIdx = IntArray(8); private val aIdx = IntArray(4)
    private val cStore = FloatArray(8)

    fun process(buf: FloatArray, frames: Int, wet: Float) {
        if (wet <= 0.001f) return
        var i = 0
        for (f in 0 until frames) {
            val input = (buf[i] + buf[i + 1]) * 0.15f
            var outL = 0f; var outR = 0f
            for (c in 0 until 4) {
                val bl = combsL[c]; val br = combsR[c]
                val yl = bl[cIdx[c]]; val yr = br[cIdx[c + 4]]
                cStore[c] = yl * 0.8f + cStore[c] * 0.2f
                cStore[c + 4] = yr * 0.8f + cStore[c + 4] * 0.2f
                bl[cIdx[c]] = input + cStore[c] * 0.84f
                br[cIdx[c + 4]] = input + cStore[c + 4] * 0.84f
                cIdx[c] = (cIdx[c] + 1) % bl.size; cIdx[c + 4] = (cIdx[c + 4] + 1) % br.size
                outL += yl; outR += yr
            }
            for (a in 0 until 2) {
                val bl = apsL[a]; val br = apsR[a]
                val vl = bl[aIdx[a]]; val vr = br[aIdx[a + 2]]
                bl[aIdx[a]] = outL + vl * 0.5f; br[aIdx[a + 2]] = outR + vr * 0.5f
                outL = vl - outL; outR = vr - outR
                aIdx[a] = (aIdx[a] + 1) % bl.size; aIdx[a + 2] = (aIdx[a + 2] + 1) % br.size
            }
            buf[i] = buf[i] * (1 - wet * 0.4f) + outL * wet
            buf[i + 1] = buf[i + 1] * (1 - wet * 0.4f) + outR * wet
            i += 2
        }
    }
}
