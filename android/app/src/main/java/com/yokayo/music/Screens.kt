package com.yokayo.music

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin

private val bottomSpace = 170.dp

// MARK: Главная

@Composable
fun HomeScreen(state: AppState, openSettings: () -> Unit) {
    val (feed, f1, r1) = rememberLoad(state, "feed") { Ym.feedPlaylists() }
    val (chart, f2, r2) = rememberLoad(state, "chart") { Ym.chart() }
    val (releases, f3, r3) = rememberLoad(state, "releases") { Ym.newReleases() }
    LazyColumn(contentPadding = PaddingValues(bottom = bottomSpace), verticalArrangement = Arrangement.spacedBy(30.dp)) {
        item { LargeTitle("Главная") { CircleButton(Icons.Default.Settings, openSettings) } }
        item { WaveCard(state) }
        if (f1 && f2 && f3) item { LoadState(false, "Не удалось загрузить главную.") { r1(); r2(); r3() } }
        if (feed == null && chart == null && !f1) item { LoadState(true, null) {} }
        feed?.takeIf { it.isNotEmpty() }?.let { list ->
            item {
                Carousel("Собрано для вас") {
                    items(list) { p -> MediaCard(p.coverUrl(), p.title, "Обновляется регулярно", 180.dp) { state.push(Screen.PlaylistPage(p)) } }
                }
            }
        }
        chart?.takeIf { it.isNotEmpty() }?.let { item { ChartGrid(state, "Чарт", it) { state.push(Screen.Chart) } } }
        releases?.takeIf { it.isNotEmpty() }?.let { list ->
            item {
                Carousel("Новые релизы") {
                    items(list.take(12)) { a -> MediaCard(a.coverUrl(), a.title, a.artist) { state.push(Screen.AlbumPage(a.id, a.title, a.cover)) } }
                }
            }
        }
    }
}

@Composable
fun Carousel(title: String, onTitle: (() -> Unit)? = null, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionTitle(title, onTitle)
        LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), content = content)
    }
}

/** Большая карточка «Моя волна»: неоновые волны живут сами и пульсируют в такт,
 *  при нажатии звезда делает оборот и от неё расходится ударная волна с искрами. */
@Composable
fun WaveCard(state: AppState) {
    val haptic = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val spin = remember { Animatable(0f) }
    val pop = remember { Animatable(1f) }
    var tapAt by remember { mutableLongStateOf(0L) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    val playing = state.isWave && state.isPlaying
    val time = frameTime()
    val density = LocalDensity.current.density

    Box(Modifier.padding(horizontal = 20.dp).fillMaxWidth().height(230.dp)
        .shadow(if (playing) 26.dp else 18.dp, RoundedCornerShape(22.dp), ambientColor = NeonDeep, spotColor = NeonDeep)
        .clip(RoundedCornerShape(22.dp))
        .border(1.2.dp, Brush.sweepGradient(listOf(Neon.copy(alpha = 0.8f), Color.Transparent, NeonDeep.copy(alpha = 0.8f), Color.Transparent, Neon.copy(alpha = 0.8f))), RoundedCornerShape(22.dp))
        .onSizeChanged { size = it }
        .press {
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            tapAt = System.currentTimeMillis()
            scope.launch { spin.animateTo(spin.value + 360f, spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessVeryLow)) }
            scope.launch { pop.animateTo(1.25f, spring(dampingRatio = 0.4f, stiffness = 900f)); pop.animateTo(1f, spring(dampingRatio = 0.6f)) }
            if (state.isWave && state.current != null) state.toggle() else state.playWave()
        }) {
        LivingBackground(listOf(NeonDeep, Color.Black, Neon, Color.Black, NeonDeep, Indigo, Neon, Color.Black, NeonDeep))
        val star = Offset(size.width * 0.8f, size.height * 0.33f)
        Canvas(Modifier.fillMaxSize()) {
            val t = time.value
            val beat = if (playing) exp(-((t * 2f) % 1f) * 5f) else 0f
            val sinceTap = if (tapAt == 0L) 99f else (System.currentTimeMillis() - tapAt) / 1000f
            val surge = if (sinceTap < 1.6f) 1 - sinceTap / 1.6f else 0f
            val d = density
            for (i in 0 until 5) {
                val k = i.toFloat()
                val amp = (9 + 5 * k + 14 * beat + 40 * surge * surge) * d
                val speed = (if (playing) 1.4f else 0.6f) + 0.15f * k
                val baseY = size.height * (0.52f + 0.09f * k)
                val p = Path()
                var x = 0f
                while (x <= size.width) {
                    val xd = x / d
                    val y = baseY + amp * sin(xd / (70 + 18 * k) + t * speed + k * 1.3f) + amp * 0.35f * sin(xd / 31 - t * speed * 1.7f)
                    if (x == 0f) p.moveTo(x, y) else p.lineTo(x, y)
                    x += 4 * d
                }
                drawPath(p, Brush.horizontalGradient(listOf(Color.Transparent, Neon.copy(alpha = 0.55f - 0.08f * k), NeonDeep.copy(alpha = 0.5f), Color.Transparent)),
                    style = Stroke((1.4f + if (i == 0) beat * 1.5f else 0f) * d))
            }
            if (sinceTap < 1.2f) {
                val e = sinceTap / 1.2f
                for (r in 0 until 3) {
                    val rr = e * 420 * (1 + r * 0.3f) * d
                    drawCircle(Neon.copy(alpha = ((1 - e) * (0.8f - 0.2f * r)).coerceIn(0f, 1f)), rr, star, style = Stroke((3 * (1 - e) + 0.5f) * d))
                }
                for (s in 0 until 18) {
                    val ang = s / 18f * 2 * Math.PI.toFloat() + (s % 3) * 0.2f
                    val dist = (30 + e * (160 + (s % 4) * 40)) * d
                    drawCircle(Color.White.copy(alpha = 1 - e), (4 * (1 - e) + 1) * d, Offset(star.x + cos(ang) * dist, star.y + sin(ang) * dist))
                }
            }
            for (s in 0 until 10) {
                val ang = t * (if (playing) 0.9f else 0.35f) + s / 10f * 2 * Math.PI.toFloat()
                val dist = (86 + 8 * sin(t * 1.3f + s) + 10 * beat) * d
                drawCircle(Color.White.copy(alpha = 0.7f), (1.4f + 0.8f * sin(t * 2 + s)) * d, Offset(star.x + cos(ang) * dist, star.y + sin(ang) * dist * 0.55f))
            }
        }
        if (size != IntSize.Zero) {
            val sp = with(LocalDensity.current) { Offset(star.x.toDp().value, star.y.toDp().value) }
            GlowingStar(120.dp, Modifier.offset((sp.x - 60).dp, (sp.y - 60).dp).scale(pop.value).rotate(spin.value))
        }
        Column(Modifier.align(Alignment.BottomStart).padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("МОЯ ВОЛНА", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, fontWeight = FontWeight.Black)
            Text("Бесконечный поток\nпод твой вкус", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, lineHeight = 27.sp)
            Row(Modifier.padding(top = 6.dp).clip(CircleShape).background(Color.White).padding(horizontal = 16.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(if (playing) Icons.Default.Pause else Icons.Default.PlayArrow, null, tint = Color.Black, modifier = Modifier.size(18.dp))
                Text(if (state.waveLoading) "Настраиваю…" else if (playing) "Играет" else "Слушать", color = Color.Black, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                if (playing) NowPlayingBars(true, Color.Black, Modifier.size(14.dp, 12.dp))
            }
        }
    }
}

// MARK: Обзор

@Composable
fun BrowseScreen(state: AppState) {
    val (playlists, failed, retry) = rememberLoad(state, "newPlaylists") { Ym.newPlaylists() }
    val (releases, _, _) = rememberLoad(state, "releases") { Ym.newReleases() }
    LazyColumn(contentPadding = PaddingValues(bottom = bottomSpace), verticalArrangement = Arrangement.spacedBy(30.dp)) {
        item { LargeTitle("Обзор") }
        if (playlists == null) item { LoadState(!failed, if (failed) "Не удалось загрузить обзор." else null, retry) }
        playlists?.firstOrNull()?.let { hero ->
            item {
                Column(Modifier.padding(horizontal = 20.dp).press { state.push(Screen.PlaylistPage(hero)) }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("НОВЫЙ ПЛЕЙЛИСТ", color = Secondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    Text(hero.title, color = Color.White, fontSize = 22.sp, maxLines = 1)
                    CoverView(hero.coverUrl(800), Modifier.fillMaxWidth().height(220.dp), corner = 14.dp)
                }
            }
        }
        playlists?.drop(1)?.takeIf { it.isNotEmpty() }?.let { list ->
            item { Carousel("Новые плейлисты") { items(list) { p -> MediaCard(p.coverUrl(), p.title, p.owner) { state.push(Screen.PlaylistPage(p)) } } } }
        }
        releases?.drop(10)?.takeIf { it.isNotEmpty() }?.let { list ->
            item { SectionTitle("Свежие альбомы") }
            items(list.chunked(2)) { row ->
                Row(Modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    row.forEach { a ->
                        Column(Modifier.weight(1f).press { state.push(Screen.AlbumPage(a.id, a.title, a.cover)) }) {
                            CoverView(a.coverUrl(), Modifier.fillMaxWidth().aspectRatio(1f))
                            Spacer(Modifier.height(6.dp))
                            Text(a.title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(a.artist, color = Secondary, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

// MARK: Медиатека

@Composable
fun LibraryScreen(state: AppState) {
    LaunchedEffect(Unit) { state.refresh() }
    LazyColumn(contentPadding = PaddingValues(bottom = bottomSpace)) {
        item { LargeTitle("Медиатека") }
        val rows = listOf(
            Triple("Мне нравится", Icons.Default.Favorite, Screen.Liked),
            Triple("Плейлисты", Icons.AutoMirrored.Filled.QueueMusic, Screen.Playlists),
            Triple("Артисты", Icons.Default.Mic, Screen.Artists),
            Triple("Статистика", Icons.Default.BarChart, Screen.Stats),
        )
        items(rows) { (title, icon, screen) ->
            Row(Modifier.fillMaxWidth().clickable { state.push(screen) }.padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, null, tint = Neon, modifier = Modifier.size(26.dp))
                Spacer(Modifier.width(16.dp))
                Text(title, color = Color.White, fontSize = 20.sp, modifier = Modifier.weight(1f))
                Icon(Icons.Default.ChevronRight, null, tint = Secondary.copy(alpha = 0.5f))
            }
            HorizontalDivider(Modifier.padding(start = 62.dp), color = Separator)
        }
        if (state.ownPlaylists.isNotEmpty()) {
            item { Text("Плейлисты Яндекса", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 20.dp, top = 28.dp, bottom = 14.dp)) }
            items(state.ownPlaylists.chunked(2)) { row ->
                Row(Modifier.padding(horizontal = 20.dp, vertical = 9.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    row.forEach { p ->
                        Column(Modifier.weight(1f).press { state.push(Screen.PlaylistPage(p)) }) {
                            CoverView(p.coverUrl(), Modifier.fillMaxWidth().aspectRatio(1f), icon = Icons.AutoMirrored.Filled.QueueMusic)
                            Spacer(Modifier.height(6.dp))
                            Text(p.title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("${p.trackCount} ${plural(p.trackCount, "трек", "трека", "треков")}", color = Secondary, fontSize = 15.sp)
                        }
                    }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
fun PlaylistsScreen(state: AppState) {
    LazyColumn(contentPadding = PaddingValues(bottom = bottomSpace)) {
        item { BackBar(state, "Плейлисты") }
        items(state.ownPlaylists) { p ->
            Row(Modifier.fillMaxWidth().clickable { state.push(Screen.PlaylistPage(p)) }.padding(horizontal = 20.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                CoverView(p.coverUrl(200), Modifier.size(56.dp), corner = 8.dp, icon = Icons.AutoMirrored.Filled.QueueMusic)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(p.title, color = Color.White, fontSize = 17.sp, maxLines = 1)
                    Text("${p.trackCount} ${plural(p.trackCount, "трек", "трека", "треков")}", color = Secondary, fontSize = 15.sp)
                }
            }
        }
    }
}

@Composable
fun ArtistsScreen(state: AppState) {
    val (artists, failed, retry) = rememberLoad(state, "likedArtists") { Ym.likedArtists() }
    LazyColumn(contentPadding = PaddingValues(bottom = bottomSpace)) {
        item { BackBar(state, "Артисты") }
        if (artists == null) item { LoadState(!failed, if (failed) "Проверь интернет и попробуй ещё раз." else null, retry) }
        items(artists ?: emptyList()) { a ->
            Row(Modifier.fillMaxWidth().clickable { state.push(Screen.ArtistPage(a)) }.padding(horizontal = 20.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                CoverView(a.coverUrl(200), Modifier.size(56.dp), corner = 28.dp, icon = Icons.Default.Person)
                Spacer(Modifier.width(14.dp))
                Text(a.name, color = Color.White, fontSize = 17.sp)
            }
        }
    }
}

// MARK: Коллекции

/** Общий экран коллекции: шапка с обложкой, «Слушать/Перемешать», список треков. */
@Composable
fun CollectionScreen(state: AppState, key: String, title: String, subtitle: String? = null, caption: String? = null,
                     cover: String? = null, numbered: Boolean = false, load: suspend () -> List<Track>) {
    val (all, failed, retry) = rememberLoad(state, key, load)
    val songs = (all ?: emptyList()).filter { Prefs.explicit || !it.explicit }
    LazyColumn(contentPadding = PaddingValues(bottom = bottomSpace)) {
        item { BackBar(state) }
        item {
            Column(Modifier.fillMaxWidth().padding(bottom = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                CoverView(cover, Modifier.padding(top = 8.dp).size(250.dp).shadow(18.dp, RoundedCornerShape(12.dp)), corner = 12.dp, icon = Icons.AutoMirrored.Filled.QueueMusic)
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(horizontal = 20.dp)) {
                    Text(title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                    subtitle?.let { Text(it, color = Neon, fontSize = 20.sp, textAlign = TextAlign.Center) }
                    caption?.let { Text(it.uppercase(), color = Secondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
                }
                PlayShuffleButtons(state, songs)
            }
        }
        if (all == null) item { LoadState(!failed, if (failed) "Проверь интернет и попробуй ещё раз." else null, retry) }
        itemsIndexed(songs, key = { i, t -> "$i${t.id}" }) { i, t ->
            TrackRow(state, t, number = i + 1, showCover = !numbered) { state.play(songs, i) }
            HorizontalDivider(Modifier.padding(start = if (numbered) 56.dp else 80.dp), color = Separator)
        }
        if (songs.isNotEmpty()) item {
            val minutes = (songs.sumOf { it.durationMs } / 60000).toInt()
            Text("${songs.size} ${plural(songs.size, "трек", "трека", "треков")}, $minutes мин.", color = Secondary, fontSize = 13.sp,
                modifier = Modifier.padding(20.dp))
        }
    }
}

@Composable
fun ArtistScreen(state: AppState, a: Artist) {
    val (info, failed, retry) = rememberLoad(state, "artist${a.id}") { Ym.artistInfo(a.id) }
    LazyColumn(contentPadding = PaddingValues(bottom = bottomSpace), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { BackBar(state) }
        item {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                CoverView(info?.first?.coverUrl(400) ?: a.coverUrl(400), Modifier.size(200.dp), corner = 100.dp, icon = Icons.Default.Person)
                Text(info?.first?.name ?: a.name, color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Bold)
                info?.second?.let { PlayShuffleButtons(state, it) }
            }
        }
        if (info == null) item { LoadState(!failed, if (failed) "Проверь интернет и попробуй ещё раз." else null, retry) }
        info?.let { (_, tracks, albums) ->
            if (tracks.isNotEmpty()) item { SectionTitle("Популярные треки") }
            itemsIndexed(tracks.take(10)) { i, t -> TrackRow(state, t) { state.play(tracks, i) } }
            if (albums.isNotEmpty()) item {
                Spacer(Modifier.height(20.dp))
                Carousel("Альбомы") { items(albums) { al -> MediaCard(al.coverUrl(), al.title, al.year?.toString()) { state.push(Screen.AlbumPage(al.id, al.title, al.cover)) } } }
            }
        }
    }
}

// MARK: Поиск

@Composable
fun SearchScreen(state: AppState) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val prefs = remember { ctx.getSharedPreferences("search", 0) }
    var history by remember { mutableStateOf(prefs.getString("h", "")!!.split("\n").filter { it.isNotBlank() }) }
    var query by remember { mutableStateOf("") }
    var result by remember { mutableStateOf<SearchResult?>(null) }
    var searching by remember { mutableStateOf(false) }
    var scope by remember { mutableIntStateOf(0) }
    val (genres, _, _) = rememberLoad(state, "genres") { Ym.genres() }

    LaunchedEffect(query) {
        val q = query.trim()
        if (q.isEmpty()) { result = null; return@LaunchedEffect }
        delay(350)
        searching = true
        val r = runCatching { Ym.search(q) }.getOrNull()
        result = r; searching = false
        if (r != null && !r.isEmpty) {
            history = (listOf(q) + history.filter { !it.equals(q, true) }).take(10)
            prefs.edit().putString("h", history.joinToString("\n")).apply()
        }
    }

    Column(Modifier.fillMaxSize()) {
        LargeTitle("Поиск")
        Row(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(40.dp).clip(RoundedCornerShape(12.dp)).background(Color(0x3D767680)).padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Search, null, tint = Secondary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(6.dp))
            Box(Modifier.weight(1f)) {
                if (query.isEmpty()) Text("Артисты, песни, альбомы", color = Secondary, fontSize = 17.sp)
                BasicTextField(query, { query = it }, singleLine = true, textStyle = TextStyle(color = Color.White, fontSize = 17.sp),
                    cursorBrush = SolidColor(Neon), modifier = Modifier.fillMaxWidth())
            }
            if (query.isNotEmpty()) Icon(Icons.Default.Cancel, null, tint = Secondary, modifier = Modifier.size(18.dp).clickable { query = "" })
        }
        Spacer(Modifier.height(10.dp))
        if (query.isBlank()) {
            LazyColumn(contentPadding = PaddingValues(bottom = bottomSpace), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (history.isNotEmpty()) {
                    item {
                        Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("Недавние", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                            Text("Очистить", color = Neon, fontSize = 15.sp, modifier = Modifier.clickable { history = emptyList(); prefs.edit().putString("h", "").apply() })
                        }
                    }
                    items(history) { q ->
                        Row(Modifier.fillMaxWidth().clickable { query = q }.padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.History, null, tint = Secondary)
                            Spacer(Modifier.width(12.dp))
                            Text(q, color = Color.White, fontSize = 17.sp)
                        }
                    }
                    item { HorizontalDivider(Modifier.padding(horizontal = 20.dp, vertical = 6.dp), color = Separator) }
                }
                item { Text("Жанры", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 20.dp)) }
                itemsIndexed((genres ?: emptyList()).chunked(2)) { r, row ->
                    Row(Modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        row.forEachIndexed { c, g ->
                            val colors = tileColors(r * 2 + c, g.color)
                            Box(Modifier.weight(1f).height(110.dp).clip(RoundedCornerShape(12.dp)).background(Brush.linearGradient(colors)).press { query = g.title },
                                contentAlignment = Alignment.BottomStart) {
                                Text(g.title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.padding(12.dp))
                            }
                        }
                        if (row.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        } else {
            val r = result
            Row(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(Color(0x3D767680)).padding(2.dp)) {
                listOf("Всё", "Треки", "Альбомы", "Артисты", "Плейлисты").forEachIndexed { i, s ->
                    Box(Modifier.weight(1f).clip(RoundedCornerShape(7.dp)).background(if (scope == i) Color(0xFF636366) else Color.Transparent)
                        .clickable { scope = i }.padding(vertical = 6.dp), contentAlignment = Alignment.Center) {
                        Text(s, color = Color.White, fontSize = 12.sp, fontWeight = if (scope == i) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1)
                    }
                }
            }
            if (searching && r == null) LoadState(true, null) {}
            if (r != null && r.isEmpty && !searching) Text("Ничего не найдено", color = Secondary, modifier = Modifier.padding(30.dp).fillMaxWidth(), textAlign = TextAlign.Center)
            if (r != null) LazyColumn(contentPadding = PaddingValues(top = 8.dp, bottom = bottomSpace)) {
                if (scope == 0 || scope == 3) items(if (scope == 0) r.artists.take(3) else r.artists) { a ->
                    Row(Modifier.fillMaxWidth().clickable { state.push(Screen.ArtistPage(a)) }.padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        CoverView(a.coverUrl(200), Modifier.size(48.dp), corner = 24.dp, icon = Icons.Default.Person)
                        Spacer(Modifier.width(12.dp))
                        Column { Text(a.name, color = Color.White, fontSize = 17.sp); Text("Артист", color = Secondary, fontSize = 15.sp) }
                    }
                }
                if (scope == 0 || scope == 1) itemsIndexed(r.tracks) { i, t -> TrackRow(state, t) { state.play(r.tracks, i) } }
                if (scope == 0 || scope == 2) items(r.albums) { a ->
                    Row(Modifier.fillMaxWidth().clickable { state.push(Screen.AlbumPage(a.id, a.title, a.cover)) }.padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        CoverView(a.coverUrl(200), Modifier.size(48.dp), corner = 5.dp)
                        Spacer(Modifier.width(12.dp))
                        Column { Text(a.title, color = Color.White, fontSize = 17.sp, maxLines = 1); Text("Альбом · ${a.artist}", color = Secondary, fontSize = 15.sp, maxLines = 1) }
                    }
                }
                if (scope == 0 || scope == 4) items(r.playlists) { p ->
                    Row(Modifier.fillMaxWidth().clickable { state.push(Screen.PlaylistPage(p)) }.padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        CoverView(p.coverUrl(200), Modifier.size(48.dp), corner = 5.dp, icon = Icons.AutoMirrored.Filled.QueueMusic)
                        Spacer(Modifier.width(12.dp))
                        Column { Text(p.title, color = Color.White, fontSize = 17.sp, maxLines = 1); Text("Плейлист · ${p.owner ?: ""}", color = Secondary, fontSize = 15.sp, maxLines = 1) }
                    }
                }
            }
        }
    }
}

private fun tileColors(i: Int, hex: String?): List<Color> {
    hex?.let { runCatching { Color(android.graphics.Color.parseColor(it)) }.getOrNull() }?.let { return listOf(it, it.copy(alpha = 0.6f)) }
    val hues = listOf(0.58f, 0.62f, 0.7f, 0.8f, 0.95f, 0.03f, 0.1f, 0.45f, 0.52f)
    val h = hues[i % hues.size]
    return listOf(Color.hsv(h * 360, 0.75f, 0.85f), Color.hsv(((h + 0.04f) % 1f) * 360, 0.85f, 0.55f))
}

// MARK: Статистика

@Composable
fun StatsScreen(state: AppState, showBack: Boolean = true) {
    var period by remember { mutableIntStateOf(7) }
    val st = state.stats
    val totals = st.totals(if (period == 0) null else period)
    val minutes = (totals.values.sum() / 60).toInt()
    val topTracks = totals.entries.sortedByDescending { it.value }.take(5)
    val byArtist = totals.entries.groupBy { st.artist(it.key) }.mapValues { e -> e.value.sumOf { it.value } }.entries.sortedByDescending { it.value }.take(5)
    LazyColumn(contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = bottomSpace), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        if (showBack) item { Box(Modifier.offset(x = (-8).dp)) { BackBar(state, "Статистика") } }
        item {
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(Color(0x3D767680)).padding(2.dp)) {
                listOf(7 to "Неделя", 30 to "Месяц", 0 to "Всё время").forEach { (v, s) ->
                    Box(Modifier.weight(1f).clip(RoundedCornerShape(7.dp)).background(if (period == v) Color(0xFF636366) else Color.Transparent)
                        .clickable { period = v }.padding(vertical = 6.dp), contentAlignment = Alignment.Center) { Text(s, color = Color.White, fontSize = 13.sp) }
                }
            }
        }
        item {
            Row(verticalAlignment = Alignment.Bottom) {
                Text("$minutes", color = Neon, fontSize = 76.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.width(10.dp))
                Text(plural(minutes, "минута", "минуты", "минут") + " музыки", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(bottom = 18.dp))
            }
            if (st.streak > 1) Text("🔥 Слушаешь ${st.streak} ${plural(st.streak, "день", "дня", "дней")} подряд", color = Color(0xFFFF9F0A), fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
        }
        item {
            Text("По дням", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            val days = st.minutesPerDay(if (period == 7) 7 else 14)
            val max = (days.maxOfOrNull { it.second } ?: 1.0).coerceAtLeast(1.0)
            Row(Modifier.fillMaxWidth().height(160.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Bottom) {
                days.forEach { (d, m) ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(Modifier.fillMaxWidth().height((130 * (m / max)).coerceAtLeast(2.0).dp).clip(RoundedCornerShape(5.dp)).background(Brush.verticalGradient(listOf(Neon, NeonDeep))))
                        Text(d.dayOfWeek.getDisplayName(java.time.format.TextStyle.NARROW, java.util.Locale("ru")), color = Secondary, fontSize = 11.sp)
                    }
                }
            }
        }
        if (byArtist.isNotEmpty()) item {
            Text("Топ артистов", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            byArtist.forEachIndexed { i, (name, s) ->
                Row(Modifier.padding(vertical = 5.dp)) {
                    Text("${i + 1}", color = Neon, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(26.dp))
                    Text(name, color = Color.White, modifier = Modifier.weight(1f), maxLines = 1)
                    Text("${(s / 60).toInt()} мин", color = Secondary)
                }
            }
        }
        if (topTracks.isNotEmpty()) item {
            Text("Топ треков", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            topTracks.forEachIndexed { i, (id, s) ->
                Row(Modifier.padding(vertical = 5.dp)) {
                    Text("${i + 1}", color = Neon, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(26.dp))
                    Column(Modifier.weight(1f)) {
                        Text(st.title(id), color = Color.White, maxLines = 1)
                        Text(st.artist(id), color = Secondary, fontSize = 14.sp, maxLines = 1)
                    }
                    Text("${(s / 60).toInt()} мин", color = Secondary)
                }
            }
        }
    }
}
