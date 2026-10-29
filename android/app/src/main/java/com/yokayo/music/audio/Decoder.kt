package com.yokayo.music.audio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import com.yokayo.music.Ym
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

/** Раскодированный трек в памяти: стерео 16 бит. Заполняется постепенно, пока идёт декодирование. */
class PcmTrack(val sampleRate: Int, capacityFrames: Int) {
    @Volatile var data = ShortArray(capacityFrames * 2); private set
    @Volatile var frames = 0; private set
    @Volatile var done = false; private set
    @Volatile var failed = false

    val duration get() = frames.toDouble() / sampleRate
    /** Длительность из заголовка — пока трек не раскодирован до конца. */
    var expectedDuration = capacityFrames.toDouble() / sampleRate

    @Synchronized fun append(src: ShortArray, count: Int, channels: Int) {
        val add = count / channels
        if ((frames + add) * 2 > data.size) data = data.copyOf(maxOf(data.size * 3 / 2, (frames + add) * 2 + 44100 * 2))
        val d = data
        var o = frames * 2
        if (channels == 2) { System.arraycopy(src, 0, d, o, add * 2) }
        else for (i in 0 until add) {
            val l = src[i * channels]; val r = if (channels > 1) src[i * channels + 1] else l
            d[o++] = l; d[o++] = r
        }
        frames += add
    }

    fun finish() { done = true; expectedDuration = duration }

    /** Моно 11025 Гц для анализа (простое усреднение + линейная интерполяция). */
    fun mono11k(): FloatArray {
        val ratio = sampleRate / 11025.0
        val n = (frames / ratio).toInt()
        val out = FloatArray(n)
        val d = data
        for (i in 0 until n) {
            val c = (i * ratio).toInt()
            var s = 0f; var k = 0
            var j = c
            val end = minOf(frames, c + ratio.toInt().coerceAtLeast(1))
            while (j < end) { s += d[j * 2] + d[j * 2 + 1]; k++; j++ }
            out[i] = if (k > 0) s / (k * 2 * 32768f) else 0f
        }
        return out
    }
}

/** Скачивание mp3 в кэш и декодирование. */
object Decoder {
    private val http = OkHttpClient()
    private val inFlight = ConcurrentHashMap<String, Any>()
    lateinit var dir: File
    private const val CACHE_LIMIT = 600L * 1024 * 1024

    fun init(ctx: Context) { dir = File(ctx.cacheDir, "stream").apply { mkdirs() } }

    private fun safe(id: String) = id.replace(":", "_").replace("/", "_")

    /** Локальный файл трека: из кэша или скачанный сейчас (блокирует поток). */
    fun file(trackId: String, maxKbps: Int): File {
        val f = File(dir, safe(trackId) + ".mp3")
        if (f.exists() && f.length() > 0) { f.setLastModified(System.currentTimeMillis()); return f }
        val lock = inFlight.getOrPut(trackId) { Any() }
        synchronized(lock) {
            if (f.exists() && f.length() > 0) return f
            val url = Ym.streamUrlBlocking(trackId.substringBefore(":"), maxKbps)
            val tmp = File(dir, safe(trackId) + ".part")
            http.newCall(Request.Builder().url(url).build()).execute().use { r ->
                if (!r.isSuccessful) throw RuntimeException("HTTP ${r.code}")
                tmp.outputStream().use { out -> r.body!!.byteStream().copyTo(out) }
            }
            tmp.renameTo(f)
        }
        inFlight.remove(trackId)
        trim()
        return f
    }

    private fun trim() {
        val files = dir.listFiles()?.filter { it.extension == "mp3" } ?: return
        var total = files.sumOf { it.length() }
        if (total <= CACHE_LIMIT) return
        for (f in files.sortedBy { it.lastModified() }) { if (total <= CACHE_LIMIT) break; total -= f.length(); f.delete() }
    }

    fun cacheBytes() = dir.listFiles()?.sumOf { it.length() } ?: 0L
    fun clearCache() { dir.listFiles()?.forEach { it.delete() } }

    /** Начать декодирование в фоне; трек можно играть сразу, по мере готовности. */
    fun decode(file: File): PcmTrack {
        val ex = MediaExtractor()
        ex.setDataSource(file.path)
        val idx = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
        ex.selectTrack(idx)
        val fmt = ex.getTrackFormat(idx)
        val sr = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val durUs = if (fmt.containsKey(MediaFormat.KEY_DURATION)) fmt.getLong(MediaFormat.KEY_DURATION) else 240_000_000L
        val track = PcmTrack(sr, (durUs / 1e6 * sr).toInt() + sr)
        Thread({
            val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
            try {
                codec.configure(fmt, null, null, 0)
                codec.start()
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                var tmp = ShortArray(8192)
                while (true) {
                    if (!inputDone) {
                        val i = codec.dequeueInputBuffer(10_000)
                        if (i >= 0) {
                            val n = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                            if (n < 0) { codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                            else { codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                        }
                    }
                    val o = codec.dequeueOutputBuffer(info, 10_000)
                    if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    if (o >= 0) {
                        val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder()).asShortBuffer()
                        val n = info.size / 2
                        if (tmp.size < n) tmp = ShortArray(n)
                        buf.get(tmp, 0, n)
                        track.append(tmp, n, channels)
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                }
            } catch (e: Exception) {
                track.failed = true
            } finally {
                runCatching { codec.stop(); codec.release() }
                ex.release()
                track.finish()
            }
        }, "decode").apply { priority = Thread.NORM_PRIORITY - 1 }.start()
        return track
    }
}
