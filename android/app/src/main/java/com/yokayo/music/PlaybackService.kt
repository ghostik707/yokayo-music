package com.yokayo.music

import android.content.Context
import android.media.audiofx.Equalizer
import android.net.ConnectivityManager
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/** Пресеты эквалайзера — те же, что на iPhone (10 полос, дБ). */
enum class EqPreset(val title: String, val gains: List<Float>) {
    FLAT("Обычный", listOf(0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f)),
    BASS("Больше баса", listOf(6f, 5f, 4f, 2f, 0f, 0f, 0f, 0f, 1f, 1f)),
    DEEP_BASS("Глубокий бас", listOf(8f, 7f, 4f, 0f, -1f, 0f, 0f, 0f, 0f, 0f)),
    VOCAL("Вокал", listOf(-2f, -2f, -1f, 1f, 3f, 4f, 3f, 2f, 0f, -1f)),
    ELECTRONIC("Электроника", listOf(5f, 4f, 2f, 0f, -2f, 0f, 1f, 2f, 4f, 4f)),
    HIPHOP("Хип-хоп", listOf(5f, 5f, 3f, 1f, -1f, -1f, 1f, 1f, 2f, 2f)),
    ROCK("Рок", listOf(4f, 3f, 2f, 0f, -1f, -1f, 1f, 3f, 4f, 4f)),
    ACOUSTIC("Акустика", listOf(3f, 2f, 2f, 1f, 1f, 1f, 2f, 3f, 2f, 1f)),
    TREBLE("Звонкий", listOf(-2f, -1f, 0f, 0f, 0f, 1f, 3f, 5f, 6f, 6f)),
    NIGHT("Тише ночью", listOf(-5f, -4f, -2f, 0f, 1f, 1f, 1f, -1f, -3f, -4f)),
    CUSTOM("Свой", List(10) { 0f });

    companion object {
        val bands = listOf(32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)
        val labels = listOf("32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K")
    }
}

/** Настройки приложения (общие для экрана и сервиса — один процесс). */
object Prefs {
    private lateinit var p: android.content.SharedPreferences
    var qualityWifi by mutableStateOf(320)
    var qualityCell by mutableStateOf(192)
    var particles by mutableStateOf(true)
    var explicit by mutableStateOf(true)
    var eqPreset by mutableStateOf(EqPreset.FLAT)
    var eqCustom by mutableStateOf(List(10) { 0f })
    var onboarded by mutableStateOf(false)

    fun init(ctx: Context) {
        if (::p.isInitialized) return
        p = ctx.getSharedPreferences("settings", Context.MODE_PRIVATE)
        qualityWifi = p.getInt("qWifi", 320); qualityCell = p.getInt("qCell", 192)
        particles = p.getBoolean("particles", true); explicit = p.getBoolean("explicit", true)
        eqPreset = runCatching { EqPreset.valueOf(p.getString("eq", "FLAT")!!) }.getOrDefault(EqPreset.FLAT)
        eqCustom = p.getString("eqCustom", null)?.split(",")?.mapNotNull { it.toFloatOrNull() }?.takeIf { it.size == 10 } ?: List(10) { 0f }
        onboarded = p.getBoolean("onboarded", false)
    }

    fun save() {
        p.edit().putInt("qWifi", qualityWifi).putInt("qCell", qualityCell).putBoolean("particles", particles)
            .putBoolean("explicit", explicit).putString("eq", eqPreset.name).putString("eqCustom", eqCustom.joinToString(","))
            .putBoolean("onboarded", onboarded).apply()
        Engine.applyEq()
    }

    val gains get() = if (eqPreset == EqPreset.CUSTOM) eqCustom else eqPreset.gains
}

/** Звуковой движок: эквалайзер на сессии плеера, выбор качества по сети. */
object Engine {
    var sessionId = 0
    private var eq: Equalizer? = null
    var appContext: Context? = null

    fun maxKbps(): Int {
        val cm = appContext?.getSystemService(ConnectivityManager::class.java)
        return if (cm?.isActiveNetworkMetered == true) Prefs.qualityCell else Prefs.qualityWifi
    }

    fun attachEq(session: Int) {
        sessionId = session
        eq = runCatching { Equalizer(0, session) }.getOrNull()
        applyEq()
    }

    /** Наши 10 полос раскладываются на полосы системного эквалайзера по ближайшей частоте. */
    fun applyEq(gains: List<Float> = Prefs.gains) {
        val e = eq ?: return
        runCatching {
            e.enabled = gains.any { it != 0f }
            val (lo, hi) = e.bandLevelRange.let { it[0] to it[1] }
            for (b in 0 until e.numberOfBands) {
                val center = e.getCenterFreq(b.toShort()) / 1000
                val i = EqPreset.bands.indices.minBy { kotlin.math.abs(kotlin.math.ln(EqPreset.bands[it].toDouble() / center.coerceAtLeast(1))) }
                e.setBandLevel(b.toShort(), (gains[i] * 100).toInt().coerceIn(lo.toInt(), hi.toInt()).toShort())
            }
        }
    }

    fun release() { eq?.release(); eq = null }
}

/** Фоновое воспроизведение: плеер живёт в сервисе, шторка и экран блокировки управляют им. */
@UnstableApi
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        Ym.init(this); Prefs.init(this)
        Engine.appContext = applicationContext
        // ym://track/<id> превращается в прямую ссылку на mp3 только перед загрузкой
        val http = DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true)
        val resolving = ResolvingDataSource.Factory(http) { spec ->
            if (spec.uri.scheme == "ym") spec.withUri(Uri.parse(Ym.streamUrlBlocking(spec.uri.lastPathSegment ?: "", Engine.maxKbps()))) else spec
        }
        val audioSession = Util.generateAudioSessionIdV21(this)
        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(resolving))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .build()
        player.audioSessionId = audioSession
        Engine.attachEq(audioSession)
        session = MediaSession.Builder(this, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = session

    override fun onDestroy() {
        Engine.release()
        session?.run { player.release(); release() }
        session = null
        super.onDestroy()
    }
}
