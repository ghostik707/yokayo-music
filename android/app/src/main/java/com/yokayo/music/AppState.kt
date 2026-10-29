package com.yokayo.music

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.LocalDate

/** Экраны внутри вкладок. */
sealed interface Screen {
    data object Home : Screen
    data object Browse : Screen
    data object Library : Screen
    data object Search : Screen
    data class PlaylistPage(val p: Playlist) : Screen
    data class AlbumPage(val id: Long, val title: String, val cover: String?) : Screen
    data class ArtistPage(val a: Artist) : Screen
    data object Liked : Screen
    data object Chart : Screen
    data object Playlists : Screen
    data object Artists : Screen
    data object Stats : Screen
}

/** Сколько и что слушал — только на телефоне. */
class ListeningStats(ctx: Context) {
    private val p = ctx.getSharedPreferences("stats", Context.MODE_PRIVATE)
    var days by mutableStateOf<Map<String, Map<String, Double>>>(emptyMap()); private set
    private val meta = mutableMapOf<String, Pair<String, String>>()
    private var pending = 0.0

    init {
        runCatching {
            val j = JSONObject(p.getString("days", "{}")!!)
            days = j.keys().asSequence().associateWith { d -> j.getJSONObject(d).let { o -> o.keys().asSequence().associateWith { o.getDouble(it) } } }
            val m = JSONObject(p.getString("meta", "{}")!!)
            m.keys().forEach { k -> m.getJSONArray(k).let { meta[k] = it.getString(0) to it.getString(1) } }
        }
    }

    fun add(t: Track, seconds: Double) {
        val k = LocalDate.now().toString()
        val day = (days[k] ?: emptyMap()).toMutableMap()
        day[t.id] = (day[t.id] ?: 0.0) + seconds
        days = days + (k to day)
        meta.getOrPut(t.id) { t.title to t.artist }
        pending += seconds
        if (pending > 15) { pending = 0.0; save() }
    }

    private fun save() {
        val j = JSONObject(); days.forEach { (d, m) -> j.put(d, JSONObject(m)) }
        val m = JSONObject(); meta.forEach { (k, v) -> m.put(k, org.json.JSONArray().put(v.first).put(v.second)) }
        p.edit().putString("days", j.toString()).putString("meta", m.toString()).apply()
    }

    fun totals(lastDays: Int?): Map<String, Double> {
        val keys = lastDays?.let { n -> (0 until n).map { LocalDate.now().minusDays(it.toLong()).toString() }.toSet() }
        val out = mutableMapOf<String, Double>()
        days.filterKeys { keys?.contains(it) ?: true }.values.forEach { m -> m.forEach { (id, s) -> out[id] = (out[id] ?: 0.0) + s } }
        return out
    }

    fun minutesPerDay(n: Int) = (n - 1 downTo 0).map { i ->
        val d = LocalDate.now().minusDays(i.toLong()); d to ((days[d.toString()]?.values?.sum() ?: 0.0) / 60)
    }

    val streak: Int get() {
        var n = 0
        while ((days[LocalDate.now().minusDays(n.toLong()).toString()]?.values?.sum() ?: 0.0) > 60) n++
        return n
    }

    fun title(id: String) = meta[id]?.first ?: "—"
    fun artist(id: String) = meta[id]?.second ?: "—"
}

/** Состояние приложения: вход, навигация, очередь, плеер, «Мне нравится». */
class AppState(app: Application) : AndroidViewModel(app) {
    var loggedIn by mutableStateOf(false); private set
    var account by mutableStateOf<Account?>(null); private set
    var current by mutableStateOf<Track?>(null); private set
    var isPlaying by mutableStateOf(false); private set
    var isLoading by mutableStateOf(false); private set
    var position by mutableLongStateOf(0); private set
    var duration by mutableLongStateOf(0); private set
    var liked by mutableStateOf<Set<String>>(emptySet()); private set
    var queue by mutableStateOf<List<Track>>(emptyList()); private set
    var queueIndex by mutableStateOf(0); private set
    var isWave by mutableStateOf(false); private set
    var waveLoading by mutableStateOf(false); private set
    var ownPlaylists by mutableStateOf<List<Playlist>>(emptyList()); private set
    var toast by mutableStateOf<String?>(null)
    var shuffle by mutableStateOf(false); private set
    var repeat by mutableStateOf(Player.REPEAT_MODE_OFF); private set

    // навигация: свой стек на каждой вкладке
    var tab by mutableStateOf(0)
    val stacks = listOf(Screen.Home, Screen.Browse, Screen.Library, Screen.Search).map { mutableStateListOf(it) }
    fun push(s: Screen) { stacks[tab].add(s) }
    fun pop(): Boolean = stacks[tab].let { if (it.size > 1) { it.removeAt(it.lastIndex); true } else false }

    val stats = ListeningStats(app)
    private var controller: MediaController? = null
    private var extending = false
    private var lastTick = 0L

    init {
        Ym.init(app); Prefs.init(app)
        loggedIn = Ym.token != null
        connect()
        if (loggedIn) refresh()
    }

    private fun connect() {
        val ctx = getApplication<Application>()
        viewModelScope.launch {
            val c = MediaController.Builder(ctx, SessionToken(ctx, ComponentName(ctx, PlaybackService::class.java))).buildAsync().await()
            controller = c
            c.addListener(object : Player.Listener {
                override fun onIsPlayingChanged(playing: Boolean) { isPlaying = playing }
                override fun onPlaybackStateChanged(state: Int) { isLoading = state == Player.STATE_BUFFERING }
                override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                    queueIndex = c.currentMediaItemIndex
                    current = queue.getOrNull(queueIndex)
                    current?.let { t -> if (isWave) viewModelScope.launch { Ym.waveFeedback(JSONObject().put("type", "trackStarted").put("trackId", t.id)) } }
                    extendWave()
                }
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) { toast = "Не удалось воспроизвести трек" }
            })
            isPlaying = c.isPlaying
        }
    }

    /** Вызывается из интерфейса 4 раза в секунду. */
    fun tick() {
        val c = controller ?: return
        position = c.currentPosition
        duration = c.duration.coerceAtLeast(0)
        val now = System.currentTimeMillis()
        if (isPlaying && lastTick > 0) current?.let { stats.add(it, (now - lastTick) / 1000.0) }
        lastTick = now
    }

    /** Только в отладочной сборке: показать интерфейс без входа (для скриншотов). */
    fun preview() { if (BuildConfig.PREVIEW) loggedIn = true }

    fun onLogin(token: String) {
        Ym.saveToken(token)
        loggedIn = true
        Prefs.onboarded = true; Prefs.save()
        refresh()
    }

    fun logout() {
        controller?.stop(); controller?.clearMediaItems()
        Ym.saveToken(null)
        loggedIn = false; account = null; liked = emptySet(); current = null; queue = emptyList()
    }

    fun refresh() = viewModelScope.launch {
        runCatching { account = Ym.account() }
        runCatching { liked = Ym.likedIds() }
        runCatching { ownPlaylists = Ym.userPlaylists() }
    }

    private fun item(t: Track) = MediaItem.Builder()
        .setMediaId(t.id)
        .setUri(Uri.Builder().scheme("ym").authority("track").appendPath(t.id).build())
        .setMediaMetadata(MediaMetadata.Builder()
            .setTitle(t.title).setArtist(t.artist)
            .setArtworkUri(t.coverUrl(600)?.let(Uri::parse))
            .build())
        .build()

    fun play(list: List<Track>, index: Int = 0, shuffled: Boolean = false, wave: Boolean = false) {
        val c = controller ?: return
        if (list.isEmpty()) return
        val l = if (shuffled) list.shuffled() else list
        val i = if (shuffled) 0 else index
        isWave = wave
        queue = l; queueIndex = i; current = l.getOrNull(i)
        c.setMediaItems(l.map(::item), i, 0)
        c.prepare(); c.play()
    }

    fun playNext(t: Track) {
        val c = controller ?: return play(listOf(t))
        if (queue.isEmpty()) return play(listOf(t))
        val at = c.currentMediaItemIndex + 1
        c.addMediaItem(at, item(t))
        queue = queue.toMutableList().apply { add(at, t) }
        toast = "Сыграет следующим"
    }

    fun playWave() = viewModelScope.launch {
        waveLoading = true
        runCatching { Ym.waveStart() }
            .onSuccess { if (it.isNotEmpty()) play(it, 0, wave = true) else toast = "Волна пустая" }
            .onFailure { toast = "Не удалось запустить волну" }
        waveLoading = false
    }

    private fun extendWave() {
        val c = controller ?: return
        if (!isWave || extending || c.currentMediaItemIndex < c.mediaItemCount - 3) return
        extending = true
        viewModelScope.launch {
            runCatching { Ym.waveMore(queue.map { it.id }) }.onSuccess { more ->
                c.addMediaItems(more.map(::item)); queue = queue + more
            }
            extending = false
        }
    }

    fun jump(i: Int) { controller?.seekTo(i, 0) }
    fun toggle() { controller?.let { if (it.isPlaying) it.pause() else it.play() } }
    fun next() {
        val c = controller ?: return
        if (isWave) current?.let { t ->
            viewModelScope.launch { Ym.waveFeedback(JSONObject().put("type", "skip").put("trackId", t.id).put("totalPlayedSeconds", c.currentPosition / 1000.0)) }
        }
        c.seekToNextMediaItem()
    }
    fun previous() { controller?.let { if (it.currentPosition > 3000) it.seekTo(0) else it.seekToPreviousMediaItem() } }
    fun seek(ms: Long) { controller?.seekTo(ms) }
    fun toggleShuffle() { controller?.let { it.shuffleModeEnabled = !it.shuffleModeEnabled; shuffle = it.shuffleModeEnabled } }
    fun cycleRepeat() {
        val c = controller ?: return
        c.repeatMode = when (c.repeatMode) { Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL; Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE; else -> Player.REPEAT_MODE_OFF }
        repeat = c.repeatMode
    }

    fun toggleLike(t: Track) {
        val now = t.baseId !in liked
        liked = if (now) liked + t.baseId else liked - t.baseId
        viewModelScope.launch {
            runCatching { Ym.setLike(t.id, now) }.onFailure { toast = "Не удалось обновить «Мне нравится»" }
        }
    }
    fun isLiked(t: Track) = t.baseId in liked

    fun addToPlaylist(t: Track, p: Playlist) = viewModelScope.launch {
        runCatching { Ym.addToPlaylist(t, p.kind) }
            .onSuccess { toast = "Добавлено в «${p.title}»"; runCatching { ownPlaylists = Ym.userPlaylists() } }
            .onFailure { toast = "Не удалось добавить в плейлист" }
    }

    /** Загрузка с кэшем по ключу — для экранов. */
    private val cache = mutableMapOf<String, Any>()
    @Suppress("UNCHECKED_CAST")
    suspend fun <T : Any> cached(key: String, load: suspend () -> T): T = (cache[key] as T?) ?: load().also { cache[key] = it }
    fun invalidate(key: String) { cache.remove(key) }
}
