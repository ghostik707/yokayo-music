package com.yokayo.music

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyHorizontalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import kotlin.math.sin

/** Обложка с заглушкой. */
@Composable
fun CoverView(url: String?, modifier: Modifier = Modifier, corner: Dp = 10.dp, icon: ImageVector = Icons.Default.MusicNote) {
    Box(modifier.clip(RoundedCornerShape(corner)).background(Brush.linearGradient(listOf(Color(0xFF1C2140), Color(0xFF0B0F22)))),
        contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = Color.White.copy(alpha = 0.35f), modifier = Modifier.fillMaxSize(0.35f))
        if (url != null) AsyncImage(url, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    }
}

/** Большой заголовок экрана, как в Apple Music. */
@Composable
fun LargeTitle(title: String, trailing: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 16.dp, top = 12.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        trailing()
    }
}

/** Кнопка-кружок в шапке (настройки, назад). */
@Composable
fun CircleButton(icon: ImageVector, onClick: () -> Unit) {
    Box(Modifier.size(44.dp).clip(RoundedCornerShape(22.dp)).background(Color.White.copy(alpha = 0.10f)).press(onClick), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = Neon, modifier = Modifier.size(24.dp))
    }
}

/** Шапка вложенного экрана: «назад». */
@Composable
fun BackBar(state: AppState, title: String = "") {
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        CircleButton(Icons.Default.ChevronLeft) { state.pop() }
        Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
        Spacer(Modifier.width(44.dp))
    }
}

/** Заголовок секции: жирный текст и шеврон. */
@Composable
fun SectionTitle(title: String, onClick: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        if (onClick != null) Icon(Icons.Default.ChevronRight, null, tint = Secondary, modifier = Modifier.size(26.dp))
    }
}

/** Карточка альбома или плейлиста для каруселей. */
@Composable
fun MediaCard(url: String?, title: String, subtitle: String?, width: Dp = 160.dp, onClick: () -> Unit) {
    Column(Modifier.width(width).press(onClick)) {
        CoverView(url, Modifier.size(width).shadow(6.dp, RoundedCornerShape(10.dp)), icon = Icons.AutoMirrored.Filled.QueueMusic)
        Spacer(Modifier.height(6.dp))
        Text(title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (subtitle != null) Text(subtitle, color = Secondary, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
fun ExplicitBadge() {
    Box(Modifier.size(13.dp).clip(RoundedCornerShape(2.5.dp)).background(Secondary), contentAlignment = Alignment.Center) {
        Text("E", color = Color.Black, fontSize = 9.sp, fontWeight = FontWeight.Black)
    }
}

/** Пляшущие столбики «сейчас играет». */
@Composable
fun NowPlayingBars(animating: Boolean, color: Color = Neon, modifier: Modifier = Modifier.size(16.dp, 14.dp)) {
    val time = frameTime()
    androidx.compose.foundation.Canvas(modifier) {
        val w = (size.width - 4.dp.toPx()) / 3
        repeat(3) { i ->
            val h = if (animating) 0.3f + 0.7f * (0.5f + 0.5f * sin(time.value * (6f + i * 2.3f) + i)) else 0.35f
            drawRoundRect(color, androidx.compose.ui.geometry.Offset(i * (w + 2.dp.toPx()), size.height * (1 - h)),
                androidx.compose.ui.geometry.Size(w, size.height * h), androidx.compose.ui.geometry.CornerRadius(1.dp.toPx()))
        }
    }
}

/** Строка трека с меню «…». */
@Composable
fun TrackRow(state: AppState, t: Track, number: Int? = null, showCover: Boolean = true, onClick: () -> Unit) {
    val isCurrent = state.current?.id == t.id
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(start = 20.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        if (number != null && !showCover) {
            Box(Modifier.width(24.dp), contentAlignment = Alignment.Center) {
                if (isCurrent) NowPlayingBars(state.isPlaying) else Text("$number", color = Secondary, fontSize = 16.sp)
            }
            Spacer(Modifier.width(12.dp))
        }
        if (showCover) {
            Box(contentAlignment = Alignment.Center) {
                CoverView(t.coverUrl(100), Modifier.size(48.dp), corner = 5.dp)
                if (isCurrent) {
                    Box(Modifier.size(48.dp).clip(RoundedCornerShape(5.dp)).background(Color.Black.copy(alpha = 0.35f)))
                    NowPlayingBars(state.isPlaying, Color.White)
                }
            }
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(t.title, color = if (isCurrent) Neon else Color.White, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (t.explicit) ExplicitBadge()
                Text(t.artist, color = Secondary, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        SongMenuButton(state, t)
    }
}

/** Меню трека: далее, лайк, плейлист, артист, альбом, поделиться. */
@Composable
fun SongMenuButton(state: AppState, t: Track, tint: Color = Color.White, circle: Boolean = false) {
    var open by remember { mutableStateOf(false) }
    var playlists by remember { mutableStateOf(false) }
    val ctx = LocalContext.current
    Box {
        Box(Modifier.size(if (circle) 34.dp else 40.dp).clip(RoundedCornerShape(20.dp))
            .background(if (circle) Color.White.copy(alpha = 0.14f) else Color.Transparent).clickable { open = true },
            contentAlignment = Alignment.Center) {
            Icon(Icons.Default.MoreHoriz, null, tint = tint)
        }
        DropdownMenu(open, { open = false; playlists = false }, containerColor = Color(0xFF1E2033)) {
            if (!playlists) {
                MenuItem("Воспроизвести далее", Icons.AutoMirrored.Filled.QueueMusic) { open = false; state.playNext(t) }
                MenuItem(if (state.isLiked(t)) "Убрать из «Мне нравится»" else "Мне нравится",
                    if (state.isLiked(t)) Icons.Default.HeartBroken else Icons.Default.Favorite) { open = false; state.toggleLike(t) }
                MenuItem("Добавить в плейлист", Icons.AutoMirrored.Filled.PlaylistAdd) { playlists = true }
                t.artistId?.let { id -> MenuItem("К артисту", Icons.Default.Person) {
                    open = false; state.push(Screen.ArtistPage(Artist(id, t.artist, null))) } }
                t.albumId?.let { id -> MenuItem("К альбому", Icons.Default.Album) {
                    open = false; state.push(Screen.AlbumPage(id, t.title, t.cover)) } }
                MenuItem("Поделиться", Icons.Default.Share) {
                    open = false
                    val url = "https://music.yandex.ru/" + (t.albumId?.let { "album/$it/" } ?: "") + "track/${t.baseId}"
                    ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
                        .putExtra(Intent.EXTRA_TEXT, "${t.artist} — ${t.title}\n$url"), null))
                }
            } else {
                Text("Плейлисты Яндекса", color = Secondary, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                if (state.ownPlaylists.isEmpty()) Text("Нет своих плейлистов", color = Secondary, modifier = Modifier.padding(16.dp))
                state.ownPlaylists.forEach { p ->
                    MenuItem(p.title, Icons.AutoMirrored.Filled.QueueMusic) { open = false; playlists = false; state.addToPlaylist(t, p) }
                }
            }
        }
    }
}

@Composable
private fun MenuItem(text: String, icon: ImageVector, onClick: () -> Unit) {
    DropdownMenuItem(text = { Text(text, color = Color.White) }, onClick = onClick, trailingIcon = { Icon(icon, null, tint = Color.White) })
}

/** Сетка треков как «Лучшие песни» в Apple Music: колонки по 4, листаются вбок. */
@Composable
fun ChartGrid(state: AppState, title: String, songs: List<Track>, onTitle: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionTitle(title, onTitle)
        LazyHorizontalGrid(GridCells.Fixed(4), Modifier.height(236.dp), contentPadding = PaddingValues(horizontal = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            itemsIndexed(songs) { i, s ->
                Row(Modifier.width(300.dp).height(56.dp).clickable { state.play(songs, i) }, verticalAlignment = Alignment.CenterVertically) {
                    CoverView(s.coverUrl(100), Modifier.size(48.dp), corner = 5.dp)
                    Text("${i + 1}", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp,
                        modifier = Modifier.width(32.dp).padding(start = 10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(s.title, color = Color.White, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(s.artist, color = Secondary, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

/** «Слушать» и «Перемешать». */
@Composable
fun PlayShuffleButtons(state: AppState, songs: List<Track>) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        listOf(Triple("Слушать", Icons.Default.PlayArrow, false), Triple("Перемешать", Icons.Default.Shuffle, true)).forEach { (title, icon, shuffle) ->
            Row(Modifier.weight(1f).height(48.dp).clip(RoundedCornerShape(12.dp)).background(Fill).press { state.play(songs, 0, shuffled = shuffle) },
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, null, tint = Neon, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(6.dp))
                Text(title, color = Neon, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
            }
        }
    }
}

/** Загрузка или ошибка с кнопкой «Повторить». */
@Composable
fun LoadState(loading: Boolean, error: String?, retry: () -> Unit) {
    when {
        loading -> Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Neon) }
        error != null -> Column(Modifier.fillMaxWidth().padding(30.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Default.WifiOff, null, tint = Secondary, modifier = Modifier.size(40.dp))
            Text(error, color = Secondary, modifier = Modifier.padding(10.dp))
            TextButton(retry) { Text("Повторить", color = Neon) }
        }
    }
}

/** Загружает данные для экрана один раз (с кэшем в AppState). */
@Composable
fun <T : Any> rememberLoad(state: AppState, key: String, load: suspend () -> T): Triple<T?, Boolean, () -> Unit> {
    var data by remember(key) { mutableStateOf<T?>(null) }
    var failed by remember(key) { mutableStateOf(false) }
    var attempt by remember(key) { mutableIntStateOf(0) }
    LaunchedEffect(key, attempt) {
        failed = false
        runCatching { state.cached(key, load) }.onSuccess { data = it }.onFailure { failed = true }
    }
    return Triple(data, failed, { state.invalidate(key); attempt++ })
}
