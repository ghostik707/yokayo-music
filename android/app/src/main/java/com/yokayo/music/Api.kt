package com.yokayo.music

import android.content.Context
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.time.Instant
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

private fun cover(uri: String?, size: Int): String? =
    uri?.takeIf { it.isNotEmpty() }?.let { "https://" + it.replace("%%", "${size}x$size") }

/** Трек Яндекс Музыки. */
data class Track(
    val id: String,
    val title: String,
    val artist: String,
    val artistId: Long?,
    val cover: String?,
    val durationMs: Long,
    val explicit: Boolean,
    val albumId: Long?,
) {
    fun coverUrl(size: Int = 400) = cover(cover, size)
    val baseId get() = id.substringBefore(":")
}

data class Playlist(val uid: Long, val kind: Long, val title: String, val cover: String?, val trackCount: Int, val owner: String?) {
    fun coverUrl(size: Int = 400) = cover(cover, size)
}

data class Album(val id: Long, val title: String, val artist: String, val cover: String?, val year: Int?) {
    fun coverUrl(size: Int = 400) = cover(cover, size)
}

data class Artist(val id: Long, val name: String, val cover: String?) {
    fun coverUrl(size: Int = 400) = cover(cover, size)
}

data class Genre(val title: String, val color: String?)

data class SearchResult(val tracks: List<Track>, val albums: List<Album>, val artists: List<Artist>, val playlists: List<Playlist>) {
    val isEmpty get() = tracks.isEmpty() && albums.isEmpty() && artists.isEmpty() && playlists.isEmpty()
}

data class LyricLine(val time: Double?, val text: String)

data class Account(val name: String, val login: String, val plus: Boolean, val avatar: String?)

/** Прямые запросы к API Яндекс Музыки. */
object Ym {
    private const val BASE = "https://api.music.yandex.net/"
    private const val CLIENT = "YandexMusicAndroid/24023131"
    private const val CLIENT_ID = "23cabbbdc6cd418abb4b39c32c41195d"
    const val LOGIN_URL = "https://oauth.yandex.ru/authorize?response_type=token&client_id=$CLIENT_ID"

    private val http = OkHttpClient()
    private lateinit var prefs: android.content.SharedPreferences

    var token: String? = null
        private set
    var uid: Long = 0
        private set

    fun init(ctx: Context) {
        if (::prefs.isInitialized) return
        prefs = ctx.getSharedPreferences("yokayo", Context.MODE_PRIVATE)
        token = prefs.getString("token", null)
        uid = prefs.getLong("uid", 0)
    }

    fun saveToken(t: String?) {
        token = t
        prefs.edit().putString("token", t).apply()
        if (t == null) { uid = 0; prefs.edit().remove("uid").apply() }
    }

    private fun builder(path: String) = Request.Builder()
        .url(if (path.startsWith("http")) path else BASE + path)
        .header("X-Yandex-Music-Client", CLIENT)
        .header("Accept-Language", "ru")
        .apply { token?.let { header("Authorization", "OAuth $it") } }

    private fun call(req: Request): String = http.newCall(req).execute().use { r ->
        val body = r.body?.string() ?: ""
        if (!r.isSuccessful) throw RuntimeException("HTTP ${r.code}")
        body
    }

    private fun result(text: String): Any = JSONObject(text).let { it.opt("result") ?: it }

    suspend fun get(path: String): Any = withContext(Dispatchers.IO) { result(call(builder(path).build())) }

    suspend fun postJson(path: String, body: JSONObject): Any = withContext(Dispatchers.IO) {
        result(call(builder(path).post(body.toString().toRequestBody("application/json".toMediaType())).build()))
    }

    suspend fun postForm(path: String, form: Map<String, String>): Any = withContext(Dispatchers.IO) {
        val b = FormBody.Builder().apply { form.forEach { (k, v) -> add(k, v) } }.build()
        result(call(builder(path).post(b).build()))
    }

    private fun JSONArray?.objects(): List<JSONObject> = this?.let { a -> (0 until a.length()).mapNotNull { a.optJSONObject(it) } } ?: emptyList()

    // MARK: Разбор

    fun track(o: JSONObject): Track? {
        val id = o.optString("id").ifEmpty { return null }
        if (o.optBoolean("available", true).not() && o.has("available")) return null
        val artists = o.optJSONArray("artists").objects()
        val album = o.optJSONArray("albums").objects().firstOrNull()
        return Track(
            id = id,
            title = o.optString("title") + (o.optString("version").takeIf { it.isNotEmpty() }?.let { " ($it)" } ?: ""),
            artist = artists.joinToString(", ") { it.optString("name") },
            artistId = artists.firstOrNull()?.optLong("id"),
            cover = o.optString("coverUri").ifEmpty { album?.optString("coverUri") }?.ifEmpty { o.optString("ogImage") }?.ifEmpty { null },
            durationMs = o.optLong("durationMs"),
            explicit = o.optString("contentWarning") == "explicit",
            albumId = album?.optLong("id"),
        )
    }

    private fun playlist(o: JSONObject): Playlist {
        val c = o.optJSONObject("cover")
        val coverUri = c?.optString("uri")?.ifEmpty { null } ?: c?.optJSONArray("itemsUri")?.optString(0) ?: o.optString("ogImage")
        val owner = o.optJSONObject("owner")
        return Playlist(owner?.optLong("uid") ?: o.optLong("uid"), o.optLong("kind"), o.optString("title"), coverUri,
            o.optInt("trackCount"), owner?.optString("name"))
    }

    private fun album(o: JSONObject) = Album(o.optLong("id"), o.optString("title"),
        o.optJSONArray("artists").objects().joinToString(", ") { it.optString("name") }, o.optString("coverUri"), o.optInt("year").takeIf { it > 0 })

    private fun artist(o: JSONObject) = Artist(o.optLong("id"), o.optString("name"), o.optJSONObject("cover")?.optString("uri"))

    private fun sequence(arr: JSONArray?) = arr.objects().mapNotNull { it.optJSONObject("track")?.let(::track) }

    // MARK: Аккаунт

    suspend fun account(): Account {
        val r = get("account/status") as JSONObject
        val acc = r.optJSONObject("account") ?: JSONObject()
        uid = acc.optLong("uid")
        prefs.edit().putLong("uid", uid).apply()
        val sub = r.optJSONObject("subscription")
        val plus = r.optJSONObject("plus")?.optBoolean("hasPlus")
            ?: ((sub?.optJSONArray("autoRenewable")?.length() ?: 0) > 0)
        val avatar = runCatching {
            withContext(Dispatchers.IO) {
                val j = JSONObject(call(Request.Builder().url("https://login.yandex.ru/info?format=json").header("Authorization", "OAuth $token").build()))
                if (j.optBoolean("is_avatar_empty")) null else "https://avatars.yandex.net/get-yapic/${j.optString("default_avatar_id")}/islands-200"
            }
        }.getOrNull()
        return Account(acc.optString("displayName").ifEmpty { acc.optString("fullName") }.ifEmpty { acc.optString("login") },
            acc.optString("login"), plus, avatar)
    }

    private suspend fun ensureUid(): Long { if (uid == 0L) account(); return uid }

    // MARK: Главная и обзор

    suspend fun feedPlaylists(): List<Playlist> {
        val r = get("feed") as JSONObject
        return r.optJSONArray("generatedPlaylists").objects().mapNotNull { it.optJSONObject("data")?.let(::playlist) }
    }

    suspend fun chart(): List<Track> {
        val r = get("landing3/chart/russia") as JSONObject
        return sequence(r.optJSONObject("chart")?.optJSONArray("tracks")).take(20)
    }

    suspend fun newReleases(): List<Album> {
        val r = get("landing3/new-releases") as JSONObject
        val ids = r.optJSONArray("newReleases")?.let { a -> (0 until minOf(a.length(), 30)).map { a.get(it).toString() } } ?: return emptyList()
        if (ids.isEmpty()) return emptyList()
        return (postForm("albums", mapOf("album-ids" to ids.joinToString(","))) as JSONArray).objects().map(::album)
    }

    suspend fun newPlaylists(): List<Playlist> {
        val r = get("landing3/new-playlists") as JSONObject
        val ids = r.optJSONArray("newPlaylists").objects().take(16).map { "${it.optLong("uid")}:${it.optLong("kind")}" }
        if (ids.isEmpty()) return emptyList()
        return (postForm("playlists/list", mapOf("playlistIds" to ids.joinToString(","))) as JSONArray).objects().map(::playlist)
    }

    suspend fun genres(): List<Genre> = (get("genres") as JSONArray).objects()
        .filter { it.optBoolean("showInMenu", true) }
        .map { Genre(it.optJSONObject("titles")?.optJSONObject("ru")?.optString("title")?.ifEmpty { null } ?: it.optString("title"),
            it.optString("color").ifEmpty { null }) }

    // MARK: Коллекции

    private suspend fun tracksByIds(ids: List<String>): List<Track> {
        val out = mutableListOf<Track>()
        for (chunk in ids.chunked(200)) {
            out += (postForm("tracks", mapOf("track-ids" to chunk.joinToString(","))) as JSONArray).objects().mapNotNull(::track)
        }
        return out
    }

    suspend fun playlistTracks(uid: Long, kind: Long): List<Track> {
        val r = get("users/$uid/playlists/$kind") as JSONObject
        val items = r.optJSONArray("tracks").objects()
        val full = items.mapNotNull { it.optJSONObject("track")?.let(::track) }
        if (full.size == items.size) return full
        return tracksByIds(items.map { o -> o.optString("id") + (o.optString("albumId").takeIf { it.isNotEmpty() }?.let { ":$it" } ?: "") })
    }

    suspend fun albumTracks(id: Long): Pair<Album, List<Track>> {
        val r = get("albums/$id/with-tracks") as JSONObject
        val vols = r.optJSONArray("volumes")
        val tracks = (0 until (vols?.length() ?: 0)).flatMap { i -> vols!!.optJSONArray(i).objects().mapNotNull(::track) }
        return album(r) to tracks
    }

    suspend fun artistInfo(id: Long): Triple<Artist, List<Track>, List<Album>> {
        val r = get("artists/$id/brief-info") as JSONObject
        return Triple(artist(r.optJSONObject("artist") ?: JSONObject()), r.optJSONArray("popularTracks").objects().mapNotNull(::track),
            r.optJSONArray("albums").objects().map(::album))
    }

    suspend fun userPlaylists(): List<Playlist> = (get("users/${ensureUid()}/playlists/list") as JSONArray).objects().map(::playlist)

    suspend fun likedArtists(): List<Artist> =
        (get("users/${ensureUid()}/likes/artists?with-timestamps=false") as JSONArray).objects().map { artist(it.optJSONObject("artist") ?: it) }

    suspend fun liked(): List<Track> {
        val r = get("users/${ensureUid()}/likes/tracks") as JSONObject
        val ids = r.optJSONObject("library")?.optJSONArray("tracks").objects().map { o ->
            o.optString("id") + (o.optString("albumId").takeIf { it.isNotEmpty() }?.let { ":$it" } ?: "")
        }
        return tracksByIds(ids)
    }

    suspend fun likedIds(): Set<String> {
        val r = get("users/${ensureUid()}/likes/tracks") as JSONObject
        return r.optJSONObject("library")?.optJSONArray("tracks").objects().map { it.optString("id") }.toSet()
    }

    suspend fun setLike(id: String, like: Boolean) {
        postForm("users/${ensureUid()}/likes/tracks/${if (like) "add-multiple" else "remove"}", mapOf("track-ids" to id.substringBefore(":")))
    }

    suspend fun addToPlaylist(t: Track, kind: Long) {
        val u = ensureUid()
        val info = get("users/$u/playlists/$kind") as JSONObject
        val tr = JSONObject().put("id", t.baseId)
        t.albumId?.let { tr.put("albumId", it.toString()) }
        val diff = JSONArray().put(JSONObject().put("op", "insert").put("at", 0).put("tracks", JSONArray().put(tr)))
        postForm("users/$u/playlists/$kind/change-relative", mapOf("diff" to diff.toString(), "revision" to info.optInt("revision", 1).toString()))
    }

    // MARK: Поиск

    suspend fun search(text: String): SearchResult {
        val q = java.net.URLEncoder.encode(text, "UTF-8")
        val r = get("search?text=$q&type=all&page=0&nocorrect=false") as JSONObject
        fun res(k: String) = r.optJSONObject(k)?.optJSONArray("results").objects()
        return SearchResult(res("tracks").mapNotNull(::track), res("albums").map(::album), res("artists").map(::artist), res("playlists").map(::playlist))
    }

    // MARK: Моя волна

    private var waveSession: String? = null
    private var waveBatch: String? = null
    private val waveSeen = mutableListOf<String>()

    suspend fun waveStart(): List<Track> {
        val r = postJson("rotor/session/new", JSONObject()
            .put("seeds", JSONArray().put("user:onyourwave"))
            .put("includeTracksInResponse", true)) as JSONObject
        waveSession = r.optString("radioSessionId")
        waveBatch = r.optString("batchId").ifEmpty { null }
        val list = sequence(r.optJSONArray("sequence"))
        waveSeen.clear(); waveSeen += list.map { it.id }
        waveFeedback(JSONObject().put("type", "radioStarted").put("from", "mobile-home-rup_main-user-onyourwave-default"))
        return list
    }

    suspend fun waveMore(queue: List<String>): List<Track> {
        val s = waveSession ?: return emptyList()
        val ids = JSONArray(); (waveSeen + queue).takeLast(30).forEach { ids.put(it) }
        val r = postJson("rotor/session/$s/tracks", JSONObject().put("queue", ids)) as JSONObject
        r.optString("batchId").takeIf { it.isNotEmpty() }?.let { waveBatch = it }
        val list = sequence(r.optJSONArray("sequence"))
        waveSeen += list.map { it.id }
        return list
    }

    suspend fun waveFeedback(event: JSONObject) {
        val s = waveSession ?: return
        event.put("timestamp", Instant.now().toString())
        val body = JSONObject().put("event", event)
        waveBatch?.let { body.put("batchId", it) }
        runCatching { postJson("rotor/session/$s/feedback", body) }
    }

    // MARK: Тексты

    suspend fun lyrics(t: Track): List<LyricLine>? = withContext(Dispatchers.IO) {
        for (format in listOf("LRC", "TEXT")) {
            val text = runCatching {
                val ts = (System.currentTimeMillis() / 1000).toString()
                val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec("p93jhgh689SBReK6ghtw62".toByteArray(), "HmacSHA256")) }
                val sign = java.net.URLEncoder.encode(Base64.encodeToString(mac.doFinal((t.baseId + ts).toByteArray()), Base64.NO_WRAP), "UTF-8")
                val r = result(call(builder("tracks/${t.baseId}/lyrics?format=$format&timeStamp=$ts&sign=$sign").build())) as JSONObject
                call(Request.Builder().url(r.getString("downloadUrl")).build())
            }.getOrNull()
            if (text.isNullOrBlank()) continue
            val lines = if (format == "LRC") parseLrc(text) else text.lines().map { LyricLine(null, it) }
            if (lines.isNotEmpty()) return@withContext lines
        }
        null
    }

    private fun parseLrc(text: String): List<LyricLine> {
        val re = Regex("""\[(\d+):(\d+(?:\.\d+)?)]""")
        return text.lines().flatMap { raw ->
            val ms = re.findAll(raw).toList()
            val line = ms.lastOrNull()?.let { raw.substring(it.range.last + 1).trim() } ?: return@flatMap emptyList()
            ms.map { LyricLine(it.groupValues[1].toDouble() * 60 + it.groupValues[2].toDouble(), line) }
        }.sortedBy { it.time }
    }

    // MARK: Ссылка на поток

    /** Прямая ссылка на mp3 с битрейтом не выше `maxKbps` (вызывается в фоновом потоке плеера). */
    fun streamUrlBlocking(trackId: String, maxKbps: Int): String {
        val infos = (result(call(builder("tracks/$trackId/download-info").build())) as JSONArray).objects()
        val mp3 = infos.filter { it.optString("codec") == "mp3" && !it.optBoolean("preview") }.sortedByDescending { it.optInt("bitrateInKbps") }
        val info = mp3.firstOrNull { it.optInt("bitrateInKbps") <= maxKbps } ?: mp3.lastOrNull() ?: infos.first()
        val xml = call(builder(info.getString("downloadInfoUrl")).build())
        fun tag(n: String) = Regex("<$n>(.*?)</$n>").find(xml)?.groupValues?.get(1) ?: ""
        val host = tag("host"); val path = tag("path"); val ts = tag("ts"); val s = tag("s")
        val md5 = MessageDigest.getInstance("MD5").digest(("XGRlBW9FXlekgbPrRHuSiA" + path.drop(1) + s).toByteArray())
        return "https://$host/get-mp3/${md5.joinToString("") { "%02x".format(it) }}/$ts$path"
    }
}
