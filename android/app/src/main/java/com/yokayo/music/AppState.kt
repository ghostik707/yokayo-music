package com.yokayo.music

import android.app.Application
import android.content.ComponentName
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.LocalDate
import com.yokayo.music.audio.PlayerCore

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

/** Состояние приложения: вход, навигация, плеер (через PlayerCore), «Мне нравится». */
class AppState(app: Application) : AndroidViewModel(app) {
    private val core = PlayerCore
    var loggedIn by mutableStateOf(false); private set
    var account by mutableStateOf<Account?>(null); private set
    var liked by mutableStateOf<Set<String>>(emptySet()); private set
    var waveLoading by mutableStateOf(false); private set
    var ownPlaylists by mutableStateOf<List<Playlist>>(emptyList()); private set
    var toast by mutableStateOf<String?>(null)
    var shuffle by mutableStateOf(false); private set

    val current get() = core.current
    val isPlaying get() = core.isPlaying
    val isLoading get() = core.isLoading
    val position get() = (core.position * 1000).toLong()
    val duration get() = (core.duration * 1000).toLong()
    val queue get() = core.queue
    val queueIndex get() = core.index
    val isWave get() = core.isWave
    /** 0 — выкл, 1 — всё, 2 — один. */
    val repeat get() = core.repeat

    // навигация: свой стек на каждой вкладке
    var tab by mutableStateOf(0)
    val stacks = listOf(Screen.Home, Screen.Browse, Screen.Library, Screen.Search).map { mutableStateListOf(it) }
    fun push(s: Screen) { stacks[tab].add(s) }
    fun pop(): Boolean = stacks[tab].let { if (it.size > 1) { it.removeAt(it.lastIndex); true } else false }

    val stats = ListeningStats(app)
    private var controller: MediaController? = null
    private var lastTick = 0L

    init {
        Ym.init(app); Prefs.init(app)
        Engine.appContext = app
        core.init(app)
        loggedIn = Ym.token != null
        core.onTrackStarted = { t -> if (core.isWave) viewModelScope.launch { Ym.waveFeedback(JSONObject().put("type", "trackStarted").put("trackId", t.id)) } }
        core.onTrackEnded = { t, played, skipped ->
            if (core.isWave) viewModelScope.launch {
                Ym.waveFeedback(JSONObject().put("type", if (skipped) "skip" else "trackFinished").put("trackId", t.id).put("totalPlayedSeconds", played))
            }
        }
        core.onNeedMore = { extendWave() }
        core.onError = { toast = it }
        // сервис нужен для шторки и экрана блокировки — подключаемся к нему
        viewModelScope.launch {
            runCatching { controller = MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync().await() }
        }
        if (loggedIn) refresh()
    }

    /** Вызывается из интерфейса 4 раза в секунду: статистика прослушивания. */
    fun tick() {
        val now = System.currentTimeMillis()
        if (isPlaying && lastTick > 0) current?.let { stats.add(it, (now - lastTick) / 1000.0) }
        lastTick = now
    }

    /** Только в сборке для скриншотов: показать интерфейс без входа. */
    fun preview() { if (BuildConfig.PREVIEW) loggedIn = true }

    fun onLogin(token: String) {
        Ym.saveToken(token)
        loggedIn = true
        Prefs.onboarded = true; Prefs.save()
        refresh()
    }

    fun logout() {
        core.pause()
        Ym.saveToken(null)
        loggedIn = false; account = null; liked = emptySet()
    }

    fun refresh() = viewModelScope.launch {
        runCatching { account = Ym.account() }
        runCatching { liked = Ym.likedIds() }
        runCatching { ownPlaylists = Ym.userPlaylists() }
    }

    fun play(list: List<Track>, index: Int = 0, shuffled: Boolean = false, wave: Boolean = false) {
        if (list.isEmpty()) return
        val l = if (shuffled) list.shuffled() else list
        core.play(l, if (shuffled) 0 else index, wave)
    }

    fun playNext(t: Track) { core.playNext(t); toast = "Сыграет следующим" }

    fun playWave() = viewModelScope.launch {
        waveLoading = true
        runCatching { Ym.waveStart() }
            .onSuccess { if (it.isNotEmpty()) play(it, 0, wave = true) else toast = "Волна пустая" }
            .onFailure { toast = "Не удалось запустить волну" }
        waveLoading = false
    }

    private var extending = false
    private fun extendWave() {
        if (extending) return
        extending = true
        viewModelScope.launch {
            runCatching { Ym.waveMore(core.queue.map { it.id }) }.onSuccess { core.append(it) }
            extending = false
        }
    }

    fun jump(i: Int) = core.jump(i)
    fun toggle() = core.toggle()
    fun next() = core.next()
    fun previous() = core.previous()
    fun seek(ms: Long) = core.seek(ms / 1000.0)
    fun toggleShuffle() { shuffle = !shuffle; if (shuffle) core.shuffleRest() }
    fun cycleRepeat() = core.cycleRepeat()

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
