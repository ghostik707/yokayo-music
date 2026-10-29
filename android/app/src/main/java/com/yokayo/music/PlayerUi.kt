package com.yokayo.music

import android.content.Context
import android.graphics.drawable.BitmapDrawable
import android.media.AudioManager
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.FormatQuote
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.palette.graphics.Palette
import coil.imageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import kotlin.math.roundToInt
import com.yokayo.music.audio.PlayerCore
import com.yokayo.music.audio.SpeedMode

private fun fmt(ms: Long): String { val s = (ms / 1000).coerceAtLeast(0); return "%d:%02d".format(s / 60, s % 60) }

/** Мини-плеер над панелью вкладок (как аксессуар таб-бара в iOS 26). */
@Composable
fun MiniPlayer(state: AppState, open: () -> Unit) {
    val t = state.current ?: return
    Row(Modifier.fillMaxWidth().height(56.dp).shadow(12.dp, RoundedCornerShape(28.dp)).clip(RoundedCornerShape(28.dp))
        .background(Color(0xF0202230)).clickable(onClick = open).padding(start = 10.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        CoverView(t.coverUrl(100), Modifier.size(36.dp), corner = 8.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(t.title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(PlayerCore.djStatus ?: t.artist, color = if (PlayerCore.djStatus != null) Neon else Secondary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box(Modifier.size(40.dp).clickable(onClick = state::toggle), contentAlignment = Alignment.Center) {
            if (state.isLoading) CircularProgressIndicator(Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
            else Icon(if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, null, tint = Color.White, modifier = Modifier.size(28.dp))
        }
        Box(Modifier.size(40.dp).clickable(onClick = state::next), contentAlignment = Alignment.Center) {
            Icon(Icons.Default.FastForward, null, tint = Color.White, modifier = Modifier.size(28.dp))
        }
    }
}

/** Цвета обложки для живого фона. */
@Composable
private fun coverColors(url: String?): List<Color> {
    val ctx = LocalContext.current
    var colors by remember { mutableStateOf(List(9) { Color(0xFF333333) }) }
    LaunchedEffect(url) {
        if (url == null) return@LaunchedEffect
        val r = ctx.imageLoader.execute(ImageRequest.Builder(ctx).data(url).allowHardware(false).size(120).build())
        val bmp = ((r as? SuccessResult)?.drawable as? BitmapDrawable)?.bitmap ?: return@LaunchedEffect
        val p = Palette.from(bmp).maximumColorCount(16).generate()
        val sw = listOfNotNull(p.darkVibrantSwatch, p.vibrantSwatch, p.darkMutedSwatch, p.mutedSwatch, p.dominantSwatch, p.lightVibrantSwatch, p.lightMutedSwatch)
            .map { s -> Color(s.rgb).let { c -> Color(c.red * 0.8f, c.green * 0.8f, c.blue * 0.8f) } }
        if (sw.isNotEmpty()) colors = List(9) { sw[(it * 3 + it / 3) % sw.size] }
    }
    val animated = colors.map { animateColorAsState(it, tween(800), label = "c").value }
    return animated
}

/** Полноэкранный плеер в стиле Apple Music. */
@Composable
fun NowPlaying(state: AppState, openLab: () -> Unit, close: () -> Unit) {
    val t = state.current ?: return
    var mode by remember { mutableIntStateOf(0) }   // 0 — обложка, 1 — текст, 2 — очередь
    var dragY by remember { mutableFloatStateOf(0f) }
    val colors = coverColors(t.coverUrl(400))
    Box(Modifier.fillMaxSize().offset { IntOffset(0, dragY.coerceAtLeast(0f).roundToInt()) }
        .pointerInput(Unit) {
            detectVerticalDragGestures(onDragEnd = { if (dragY > 300) close() else dragY = 0f }, onDragCancel = { dragY = 0f }) { _, d -> dragY += d }
        }) {
        LivingBackground(colors)
        if (Prefs.particles) ParticleField(count = 28, color = Color.White)
        Column(Modifier.fillMaxSize().systemBarsPadding()) {
            Box(Modifier.padding(top = 8.dp).size(38.dp, 5.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.35f)).align(Alignment.CenterHorizontally))
            if (mode == 0) {
                BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    val w = minOf(maxWidth - 56.dp, maxHeight - 32.dp)
                    val scale by animateFloatAsState(if (state.isPlaying) 1f else 0.78f, spring(dampingRatio = 0.68f, stiffness = 300f), label = "art")
                    AnimatedContent(t.id, transitionSpec = { (scaleIn(initialScale = 0.9f) + fadeIn()) togetherWith fadeOut() }, label = "cover") { _ ->
                        CoverView(t.coverUrl(800), Modifier.size(w).scale(scale).shadow(if (state.isPlaying) 30.dp else 12.dp, RoundedCornerShape(12.dp)), corner = 12.dp)
                    }
                }
                Info(state, t, openLab, Modifier.padding(horizontal = 28.dp))
            } else {
                Row(Modifier.padding(horizontal = 28.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    CoverView(t.coverUrl(200), Modifier.size(64.dp).shadow(8.dp, RoundedCornerShape(8.dp)), corner = 8.dp)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(t.title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, maxLines = 1)
                        Text(t.artist, color = Color.White.copy(alpha = 0.65f), fontSize = 17.sp, maxLines = 1)
                    }
                }
                Box(Modifier.weight(1f)) { if (mode == 1) Lyrics(state, t) else Queue(state) }
            }
            ScrubBar(state, Modifier.padding(horizontal = 28.dp).padding(top = 14.dp))
            Controls(state, Modifier.padding(top = 18.dp))
            VolumeBar(Modifier.padding(horizontal = 28.dp).padding(top = 22.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 36.dp).padding(top = 18.dp, bottom = 8.dp), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(34.dp).clickable { Prefs.djEnabled = !Prefs.djEnabled; Prefs.save(); if (Prefs.djEnabled) PlayerCore.prepareNext() }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Album, null, tint = if (Prefs.djEnabled) Neon else Color.White.copy(alpha = 0.6f), modifier = Modifier.size(24.dp))
                }
                BottomIcon(Icons.Outlined.FormatQuote, mode == 1) { mode = if (mode == 1) 0 else 1 }
                BottomIcon(if (state.repeat == 2) Icons.Default.RepeatOne else Icons.Default.Repeat,
                    state.repeat != 0) { state.cycleRepeat() }
                BottomIcon(Icons.Default.FormatListBulleted, mode == 2) { mode = if (mode == 2) 0 else 2 }
            }
        }
    }
}

@Composable
private fun BottomIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, active: Boolean, onClick: () -> Unit) {
    Box(Modifier.size(34.dp).clip(RoundedCornerShape(8.dp)).background(if (active) Color.White.copy(alpha = 0.85f) else Color.Transparent).clickable(onClick = onClick),
        contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = if (active) Color.Black else Color.White.copy(alpha = 0.75f), modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun Info(state: AppState, t: Track, openLab: () -> Unit, modifier: Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(t.title, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, false))
                if (t.explicit) ExplicitBadge()
            }
            Text(t.artist, color = Color.White.copy(alpha = 0.65f), fontSize = 20.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            PlayerCore.djStatus?.let { Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Default.Album, null, tint = Neon, modifier = Modifier.size(14.dp)); Spacer(Modifier.width(4.dp)); Text(it, color = Neon, fontSize = 12.sp, fontWeight = FontWeight.SemiBold) } }
            if (PlayerCore.speed != SpeedMode.NORMAL) Text(PlayerCore.speed.title, color = Neon, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
        val liked = state.isLiked(t)
        val bounce by animateFloatAsState(if (liked) 1f else 0.9f, spring(dampingRatio = 0.35f, stiffness = 500f), label = "like")
        Box(Modifier.size(34.dp).scale(bounce).clip(CircleShape).background(Color.White.copy(alpha = 0.14f)).clickable { state.toggleLike(t) },
            contentAlignment = Alignment.Center) {
            Icon(if (liked) Icons.Default.Favorite else Icons.Outlined.FavoriteBorder, null, tint = Color.White, modifier = Modifier.size(20.dp))
        }
        PlayerMenu(openLab)
        SongMenuButton(state, t, circle = true)
    }
}

/** Прогресс трека: тонкая полоса, которая утолщается при перетаскивании. */
@Composable
private fun ScrubBar(state: AppState, modifier: Modifier) {
    var dragging by remember { mutableStateOf<Float?>(null) }
    var width by remember { mutableIntStateOf(1) }
    val dur = state.duration.coerceAtLeast(1)
    val value = dragging ?: (state.position.toFloat() / dur).coerceIn(0f, 1f)
    val h by animateDpAsState(if (dragging != null) 12.dp else 7.dp, label = "h")
    Column(modifier) {
        Box(Modifier.fillMaxWidth().height(24.dp).onSizeChanged { width = it.width }
            .pointerInput(dur) {
                detectHorizontalDragGestures(
                    onDragStart = { dragging = (it.x / width).coerceIn(0f, 1f) },
                    onDragEnd = { dragging?.let { state.seek((it * dur).toLong()) }; dragging = null },
                    onDragCancel = { dragging = null }) { ch, _ -> dragging = (ch.position.x / width).coerceIn(0f, 1f) }
            }
            .pointerInput(dur) { detectTapGestures { state.seek((it.x / width * dur).toLong()) } },
            contentAlignment = Alignment.CenterStart) {
            Box(Modifier.fillMaxWidth().height(h).clip(CircleShape).background(Color.White.copy(alpha = 0.25f)))
            Box(Modifier.fillMaxWidth(value).height(h).clip(CircleShape).background(Color.White.copy(alpha = if (dragging != null) 1f else 0.75f)))
        }
        Row(Modifier.fillMaxWidth()) {
            Text(fmt(dragging?.let { (it * dur).toLong() } ?: state.position), color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp)
            Spacer(Modifier.weight(1f))
            Text("-" + fmt(dur - (dragging?.let { (it * dur).toLong() } ?: state.position)), color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp)
        }
    }
}

@Composable
private fun Controls(state: AppState, modifier: Modifier) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(70.dp).press(state::previous), contentAlignment = Alignment.Center) {
            Icon(Icons.Default.FastRewind, null, tint = Color.White, modifier = Modifier.size(46.dp))
        }
        Box(Modifier.size(80.dp, 70.dp).press(state::toggle), contentAlignment = Alignment.Center) {
            if (state.isLoading) CircularProgressIndicator(color = Color.White)
            else AnimatedContent(state.isPlaying, transitionSpec = { (scaleIn() + fadeIn()) togetherWith (scaleOut() + fadeOut()) }, label = "pp") { p ->
                Icon(if (p) Icons.Default.Pause else Icons.Default.PlayArrow, null, tint = Color.White, modifier = Modifier.size(64.dp))
            }
        }
        Box(Modifier.size(70.dp).press(state::next), contentAlignment = Alignment.Center) {
            Icon(Icons.Default.FastForward, null, tint = Color.White, modifier = Modifier.size(46.dp))
        }
    }
}

/** Громкость системы. */
@Composable
private fun VolumeBar(modifier: Modifier) {
    val ctx = LocalContext.current
    val am = remember { ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    var v by remember { mutableFloatStateOf(am.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / max) }
    var width by remember { mutableIntStateOf(1) }
    LaunchedEffect(Unit) { while (true) { kotlinx.coroutines.delay(1000); v = am.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / max } }
    fun set(x: Float) { v = x.coerceIn(0f, 1f); am.setStreamVolume(AudioManager.STREAM_MUSIC, (v * max).roundToInt(), 0) }
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.AutoMirrored.Filled.VolumeDown, null, tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(18.dp))
        Box(Modifier.weight(1f).padding(horizontal = 10.dp).height(24.dp).onSizeChanged { width = it.width }
            .pointerInput(Unit) { detectDragGestures { ch, _ -> set(ch.position.x / width) } }
            .pointerInput(Unit) { detectTapGestures { set(it.x / width) } }, contentAlignment = Alignment.CenterStart) {
            Box(Modifier.fillMaxWidth().height(7.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.25f)))
            Box(Modifier.fillMaxWidth(v).height(7.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.75f)))
        }
        Icon(Icons.AutoMirrored.Filled.VolumeUp, null, tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(18.dp))
    }
}

/** Тексты: синхронные строки подсвечиваются и прокручиваются, по нажатию — перемотка. */
@Composable
private fun Lyrics(state: AppState, t: Track) {
    var lines by remember(t.id) { mutableStateOf<List<LyricLine>?>(null) }
    var failed by remember(t.id) { mutableStateOf(false) }
    LaunchedEffect(t.id) { val l = state.cached("lyrics${t.id}") { Ym.lyrics(t) ?: emptyList() }; lines = l; failed = l.isEmpty() }
    val list = lines
    when {
        list == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Color.White) }
        failed -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Текста нет", color = Color.White.copy(alpha = 0.6f), fontSize = 20.sp) }
        else -> {
            val synced = list.any { it.time != null }
            val pos = state.position / 1000.0
            val active = if (synced) list.indexOfLast { (it.time ?: 0.0) <= pos } else -1
            val ls = rememberLazyListState()
            LaunchedEffect(active) { if (active >= 0) ls.animateScrollToItem((active - 2).coerceAtLeast(0)) }
            LazyColumn(state = ls, contentPadding = PaddingValues(horizontal = 28.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                itemsIndexed(list) { i, l ->
                    val a by animateFloatAsState(if (!synced || i == active) 1f else 0.35f, label = "l")
                    Text(l.text.ifEmpty { "♪" }, color = Color.White.copy(alpha = a), fontSize = 28.sp, fontWeight = FontWeight.Bold, lineHeight = 34.sp,
                        modifier = Modifier.clickable(enabled = l.time != null) { state.seek(((l.time ?: 0.0) * 1000).toLong()) })
                }
            }
        }
    }
}

@Composable
private fun Queue(state: AppState) {
    val ls = rememberLazyListState(state.queueIndex)
    LazyColumn(state = ls, contentPadding = PaddingValues(vertical = 8.dp)) {
        item { Text("Далее", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 28.dp, vertical = 8.dp)) }
        itemsIndexed(state.queue) { i, t ->
            Row(Modifier.fillMaxWidth().clickable { state.jump(i) }.padding(horizontal = 28.dp, vertical = 6.dp).then(if (i < state.queueIndex) Modifier.layerAlpha(0.45f) else Modifier),
                verticalAlignment = Alignment.CenterVertically) {
                CoverView(t.coverUrl(100), Modifier.size(44.dp), corner = 5.dp)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(t.title, color = if (i == state.queueIndex) Neon else Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(t.artist, color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (i == state.queueIndex) NowPlayingBars(state.isPlaying, Color.White)
            }
        }
    }
}

/** Меню плеера: скорость (Sped up / Slowed) и DJ-лаборатория. */
@Composable
private fun PlayerMenu(openLab: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Box(Modifier.size(34.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.14f)).clickable { open = true }, contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Speed, null, tint = Color.White, modifier = Modifier.size(20.dp))
        }
        DropdownMenu(open, { open = false }, containerColor = Color(0xFF1E2033)) {
            SpeedMode.entries.forEach { m ->
                DropdownMenuItem(text = { Text(m.title, color = Color.White) }, onClick = { PlayerCore.changeSpeed(m); open = false },
                    trailingIcon = { if (PlayerCore.speed == m) Icon(Icons.Default.Check, null, tint = Neon) })
            }
            HorizontalDivider(color = Separator)
            DropdownMenuItem(text = { Text("DJ-лаборатория", color = Color.White) }, onClick = { open = false; openLab() },
                trailingIcon = { Icon(Icons.Default.Science, null, tint = Color.White) })
        }
    }
}
