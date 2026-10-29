package com.yokayo.music

import android.content.Context
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.yokayo.music.audio.PlayerCore

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

/** Настройки приложения (общие для экрана и движка — один процесс). */
object Prefs {
    private lateinit var p: android.content.SharedPreferences
    var qualityWifi by mutableStateOf(320)
    var qualityCell by mutableStateOf(192)
    var particles by mutableStateOf(true)
    var explicit by mutableStateOf(true)
    var eqPreset by mutableStateOf(EqPreset.FLAT)
    var eqCustom by mutableStateOf(List(10) { 0f })
    var onboarded by mutableStateOf(false)
    var djEnabled by mutableStateOf(false)
    var djFx by mutableStateOf(0.6f)
    var djSmartOrder by mutableStateOf(false)
    var djGlide by mutableStateOf(true)
    var crossfade by mutableStateOf(0)
    /** Пока тянешь ползунок эквалайзера — слышно сразу. */
    @Volatile var previewGains: List<Float>? = null

    fun init(ctx: Context) {
        if (::p.isInitialized) return
        p = ctx.getSharedPreferences("settings", Context.MODE_PRIVATE)
        qualityWifi = p.getInt("qWifi", 320); qualityCell = p.getInt("qCell", 192)
        particles = p.getBoolean("particles", true); explicit = p.getBoolean("explicit", true)
        eqPreset = runCatching { EqPreset.valueOf(p.getString("eq", "FLAT")!!) }.getOrDefault(EqPreset.FLAT)
        eqCustom = p.getString("eqCustom", null)?.split(",")?.mapNotNull { it.toFloatOrNull() }?.takeIf { it.size == 10 } ?: List(10) { 0f }
        onboarded = p.getBoolean("onboarded", false)
        djEnabled = p.getBoolean("dj", false); djFx = p.getFloat("djFx", 0.6f); djSmartOrder = p.getBoolean("djSmart", false)
        djGlide = p.getBoolean("djGlide", true); crossfade = p.getInt("crossfade", 0)
    }

    fun save() {
        p.edit().putInt("qWifi", qualityWifi).putInt("qCell", qualityCell).putBoolean("particles", particles)
            .putBoolean("explicit", explicit).putString("eq", eqPreset.name).putString("eqCustom", eqCustom.joinToString(","))
            .putBoolean("onboarded", onboarded).putBoolean("dj", djEnabled).putFloat("djFx", djFx).putBoolean("djSmart", djSmartOrder)
            .putBoolean("djGlide", djGlide).putInt("crossfade", crossfade).apply()
    }

    val gains get() = previewGains ?: if (eqPreset == EqPreset.CUSTOM) eqCustom else eqPreset.gains
}

/** Выбор качества по сети. */
object Engine {
    var appContext: Context? = null
    fun maxKbps(): Int {
        val cm = appContext?.getSystemService(ConnectivityManager::class.java)
        return if (cm?.isActiveNetworkMetered == true) Prefs.qualityCell else Prefs.qualityWifi
    }
}

/** Плеер для системы (шторка, экран блокировки, наушники) поверх нашего движка. */
@UnstableApi
class CorePlayer : SimpleBasePlayer(Looper.getMainLooper()) {
    private val commands = Player.Commands.Builder().addAll(
        COMMAND_PLAY_PAUSE, COMMAND_SEEK_TO_NEXT, COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, COMMAND_SEEK_TO_PREVIOUS,
        COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM, COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM, COMMAND_GET_CURRENT_MEDIA_ITEM,
        COMMAND_GET_TIMELINE, COMMAND_GET_METADATA, COMMAND_STOP).build()

    fun refresh() = invalidateState()

    override fun getState(): State {
        val c = PlayerCore
        val items = c.queue.mapIndexed { i, t ->
            MediaItemData.Builder("$i:${t.id}")
                .setMediaItem(MediaItem.Builder().setMediaId(t.id).setMediaMetadata(MediaMetadata.Builder()
                    .setTitle(t.title).setArtist(t.artist).setArtworkUri(t.coverUrl(600)?.let(Uri::parse)).build()).build())
                .setDurationUs(if (i == c.index) (c.duration * 1e6).toLong() else t.durationMs * 1000)
                .build()
        }
        val b = State.Builder().setAvailableCommands(commands).setPlaylist(items)
            .setPlayWhenReady(c.isPlaying, PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackState(if (items.isEmpty()) STATE_IDLE else if (c.isLoading) STATE_BUFFERING else STATE_READY)
        if (items.isNotEmpty()) b.setCurrentMediaItemIndex(c.index.coerceIn(0, items.size - 1)).setContentPositionMs { (PlayerCore.position * 1000).toLong() }
        return b.build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if (playWhenReady) PlayerCore.resume() else PlayerCore.pause()
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        when (seekCommand) {
            COMMAND_SEEK_TO_NEXT, COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> PlayerCore.next()
            COMMAND_SEEK_TO_PREVIOUS, COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> PlayerCore.previous()
            else -> if (mediaItemIndex == PlayerCore.index) PlayerCore.seek(positionMs / 1000.0) else PlayerCore.jump(mediaItemIndex)
        }
        return Futures.immediateVoidFuture()
    }

    override fun handleStop(): ListenableFuture<*> { PlayerCore.pause(); return Futures.immediateVoidFuture() }
}

/** Фоновое воспроизведение: сервис держит сессию, звук играет движок PlayerCore. */
@UnstableApi
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        Ym.init(this); Prefs.init(this)
        Engine.appContext = applicationContext
        PlayerCore.init(this)
        val player = CorePlayer()
        PlayerCore.onChange = { player.refresh() }
        session = MediaSession.Builder(this, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = session

    override fun onDestroy() {
        session?.run { player.release(); release() }
        session = null
        super.onDestroy()
    }
}
