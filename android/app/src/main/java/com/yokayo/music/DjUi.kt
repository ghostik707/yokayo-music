package com.yokayo.music

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yokayo.music.audio.Analyzer
import com.yokayo.music.audio.MixComposer
import com.yokayo.music.audio.MixBrain
import com.yokayo.music.audio.PlayerCore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Настройки DJ-режима — как на iPhone. */
@Composable
fun DjSettingsPage(openLab: () -> Unit) {
    val time by frameTime()
    Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 30.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.fillMaxWidth().glass().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Default.Album, null, tint = Neon, modifier = Modifier.size(64.dp).rotate(if (Prefs.djEnabled && PlayerCore.isPlaying) time * 120 else 0f))
            Text("DJ-режим", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Text("Yokayo сам определяет темп, сильные доли и энергию треков и сводит их в непрерывный сет. Всё считается на телефоне.",
                color = Secondary, fontSize = 15.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Включить DJ-режим", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.weight(1f))
                NeonSwitch(Prefs.djEnabled) { Prefs.djEnabled = it; Prefs.save(); if (it) PlayerCore.prepareNext() }
            }
        }
        Row(Modifier.fillMaxWidth().glass().press(openLab).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(Brush.linearGradient(listOf(Color(0xFFFF375F), Color(0xFFBF5AF2)))), contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Science, null, tint = Color.White)
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text("DJ-лаборатория", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                Text("Выбери два любых трека — ИИ соберёт переход, сыграет его и покажет, что делает каждая дека.", color = Secondary, fontSize = 13.sp)
            }
            Icon(Icons.Default.ChevronRight, null, tint = Secondary)
        }
        Column(Modifier.fillMaxWidth().glass().padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("КАК СВОДИТ ИИ", color = Neon, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            Bullet(Icons.Default.Psychology, "Доли и сильные доли слышит своя нейросеть BeatNet — обучена с нуля и работает прямо на телефоне, без интернета")
            Bullet(Icons.Default.GraphicEq, "Разбирает каждый трек: темп, сетку битов, фразы, интро, дроп, аутро, тональность")
            Bullet(Icons.Default.AutoAwesome, "Каждый переход сочиняется заново: ИИ собирает сотни вариантов из приёмов — фильтры, эхо, реверб, обмен басами, бит-ролл, нарезка, стоп-пластинка, перемотка, тишина перед дропом — и «прослушивает» их по энергии и басу обоих треков")
            Bullet(Icons.Default.Speaker, "Басы не наслаиваются, громкость не проваливается, стиль подходит треку: мощный дроп — райзер и удар, спокойная пара — длинный мягкий микс")
            Bullet(Icons.Default.Shuffle, "Недавние переходы не повторяются")
            Bullet(Icons.Default.Favorite, "Учится на тебе: переключил трек сразу после перехода — такой будет реже; 👍/👎 в DJ-лаборатории")
        }
        Column(Modifier.fillMaxWidth().glass().padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("СВЕДЕНИЕ", color = Neon, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            Text("Эффекты перехода", color = Color.White, fontSize = 17.sp)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.VolumeMute, null, tint = Secondary)
                Slider(Prefs.djFx, { Prefs.djFx = it }, Modifier.weight(1f), onValueChangeFinished = { Prefs.save() },
                    colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Neon, inactiveTrackColor = Fill))
                Icon(Icons.Default.AutoAwesome, null, tint = Secondary)
            }
            ToggleLine("Возвращать родной темп", null, Prefs.djGlide) { Prefs.djGlide = it; Prefs.save() }
            ToggleLine("Умная очередь", "ИИ ставит следующим из трёх ближайших тот трек, что лучше сводится по темпу и тональности. Тратит чуть больше трафика.", Prefs.djSmartOrder) {
                Prefs.djSmartOrder = it; Prefs.save(); PlayerCore.prepareNext()
            }
        }
    }
}

fun Modifier.glass() = this.clip(RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.06f)).border(1.dp, Color.White.copy(alpha = 0.07f), RoundedCornerShape(20.dp))

@Composable
private fun Bullet(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = Neon, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Text(text, color = Secondary, fontSize = 14.sp)
    }
}

@Composable
fun NeonSwitch(value: Boolean, set: (Boolean) -> Unit) = Switch(value, set, colors = SwitchDefaults.colors(checkedTrackColor = NeonDeep, checkedThumbColor = Color.White,
    uncheckedTrackColor = Color(0x3D787880), uncheckedBorderColor = Color.Transparent, uncheckedThumbColor = Color.White))

@Composable
private fun ToggleLine(title: String, sub: String?, value: Boolean, set: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = Color.White, fontSize = 17.sp)
            sub?.let { Text(it, color = Secondary, fontSize = 12.sp) }
        }
        NeonSwitch(value, set)
    }
}

// MARK: DJ-лаборатория

/** DJ-лаборатория: выбери два трека — ИИ соберёт и сыграет переход. */
@Composable
fun DjLabScreen(state: AppState, close: () -> Unit) {
    var a by remember { mutableStateOf<Track?>(null) }
    var b by remember { mutableStateOf<Track?>(null) }
    var picking by remember { mutableIntStateOf(-1) }
    var started by remember { mutableStateOf(false) }
    var finding by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun play() {
        val ta = a ?: return; val tb = b ?: return
        busy = true; started = true
        PlayerCore.playDemo(ta, tb) { err -> busy = false; err?.let { state.toast = it } }
    }

    Box(Modifier.fillMaxSize()) {
        YokayoBackground()
        Column(Modifier.fillMaxSize().systemBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                CircleButton(Icons.Default.ChevronLeft, close)
                Text("DJ-лаборатория", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.weight(1f).padding(start = 12.dp))
            }
            Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                Text("Выбери два трека — ИИ послушает их, соберёт переход и сыграет его. Видно, что делает каждая дека.",
                    color = Secondary, fontSize = 15.sp, modifier = Modifier.padding(horizontal = 20.dp))
                Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Slot("A", a, Modifier.weight(1f)) { picking = 0 }
                    Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = Neon)
                    Slot("B", b, Modifier.weight(1f)) { picking = 1 }
                }
                Row(Modifier.padding(horizontal = 20.dp).fillMaxWidth().height(46.dp).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.08f))
                    .clickable(enabled = finding == null) {
                        finding = "ИИ ищет пару…"
                        scope.launch {
                            val pair = findPair(state) { finding = it }
                            finding = null
                            if (pair != null) { a = pair.first; b = pair.second; state.toast = "Пара найдена" } else state.toast = "Не нашёл пару — выбери треки вручную"
                        }
                    }, horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    if (finding != null) CircularProgressIndicator(Modifier.size(18.dp), color = Neon, strokeWidth = 2.dp) else Icon(Icons.Default.AutoFixHigh, null, tint = Color.White)
                    Spacer(Modifier.width(10.dp))
                    Text(finding ?: "Подобрать пару — ИИ", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                }
                Row(Modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    val ready = a != null && b != null && !busy
                    Row(Modifier.weight(1f).height(56.dp).alpha(if (ready) 1f else 0.5f).shadow(16.dp, RoundedCornerShape(16.dp), ambientColor = Neon, spotColor = Neon)
                        .clip(RoundedCornerShape(16.dp)).background(Brush.horizontalGradient(listOf(Neon, NeonDeep))).press { if (ready) play() },
                        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                        if (busy) CircularProgressIndicator(Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp) else Icon(Icons.Default.PlayArrow, null, tint = Color.White)
                        Spacer(Modifier.width(8.dp))
                        Text(if (busy) "ИИ слушает треки…" else "Сыграть переход", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                    }
                    if (started) Box(Modifier.size(56.dp).clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.1f)).press { if (!busy) play() },
                        contentAlignment = Alignment.Center) { Icon(Icons.Default.Casino, null, tint = Color.White, modifier = Modifier.size(28.dp)) }
                }
                if (started) Text("🎲 — ИИ сочинит другой переход для этой пары.", color = Secondary, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 20.dp))
                if (started || PlayerCore.djStatus != null) LiveDecks(Modifier.padding(horizontal = 20.dp))
                val r = PlayerCore.lastRecipe
                if (started && r != null) RateMix(r, Modifier.padding(horizontal = 20.dp))
            }
        }
        if (picking >= 0) TrackPicker(state, { picking = -1 }) { t -> if (picking == 0) a = t else b = t; picking = -1 }
    }
}

private suspend fun findPair(state: AppState, note: (String) -> Unit): Pair<Track, Track>? = withContext(Dispatchers.IO) {
    val liked = runCatching { state.cached("liked") { Ym.liked() } }.getOrNull()?.take(10) ?: return@withContext null
    val analyzed = mutableListOf<Pair<Track, com.yokayo.music.audio.TrackAnalysis>>()
    for ((i, t) in liked.withIndex()) {
        withContext(Dispatchers.Main) { note("ИИ слушает ${i + 1} из ${liked.size}…") }
        val a = Analyzer.cached(t.id) ?: runCatching {
            val p = com.yokayo.music.audio.Decoder.decode(com.yokayo.music.audio.Decoder.file(t.id, Engine.maxKbps()))
            Analyzer.analyze(t.id, p)
        }.getOrNull()
        if (a != null) analyzed += t to a
    }
    var best: Triple<Track, Track, Double>? = null
    for (x in analyzed) for (y in analyzed) if (x !== y) {
        val s = MixComposer.compatibility(x.second, y.second)
        if (s > (best?.third ?: -1.0)) best = Triple(x.first, y.first, s)
    }
    best?.let { it.first to it.second }
}

@Composable
private fun Slot(name: String, t: Track?, modifier: Modifier, onClick: () -> Unit) {
    Column(modifier.glass().press(onClick).padding(10.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CoverView(t?.coverUrl(300), Modifier.fillMaxWidth().aspectRatio(1f), icon = Icons.Default.Add)
        Text(t?.title ?: "Трек $name", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(t?.artist ?: "Выбрать", color = Secondary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Живая панель: две деки, кроссфейдер, фильтры и решение ИИ. */
@Composable
fun LiveDecks(modifier: Modifier = Modifier) {
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(50); tick++ } }
    @Suppress("UNUSED_EXPRESSION") tick
    val s = PlayerCore.snapshot()
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.06f))
        .border(1.dp, Neon.copy(alpha = 0.25f), RoundedCornerShape(18.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(if (s.progress > 0) Icons.Default.GraphicEq else Icons.Default.HourglassTop, null, tint = Neon)
            Spacer(Modifier.width(8.dp))
            Text(s.plan?.headline ?: "Ждём переход", color = Neon, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, maxLines = 1, modifier = Modifier.weight(1f))
            if (s.progress > 0) Text("${(s.progress * 100).toInt()}%", color = Color.White, fontWeight = FontWeight.SemiBold)
        }
        LinearProgressIndicator({ s.progress.toFloat() }, Modifier.fillMaxWidth(), color = Neon, trackColor = Fill)
        s.plan?.let { m ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                m.steps.forEachIndexed { i, step ->
                    val reached = s.progress >= if (i == 0) 0.001 else if (i == 1) m.swapAt else minOf(1.0, m.swapAt + 0.05)
                    Row {
                        Icon(if (reached) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked, null, tint = if (reached) Neon else Secondary, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(step, color = if (reached) Color.White else Secondary, fontSize = 13.sp)
                    }
                }
            }
        }
        DeckRow("A", s.a)
        // кроссфейдер
        Box(Modifier.fillMaxWidth().height(22.dp), contentAlignment = Alignment.CenterStart) {
            Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Fill))
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                Box(Modifier.offset(x = (maxWidth - 30.dp) * s.crossfade).size(30.dp, 18.dp).clip(RoundedCornerShape(5.dp)).background(Color.White))
            }
        }
        s.b?.let { DeckRow("B", it) }
        PlayerCore.djDecision?.let { Row { Icon(Icons.Default.Psychology, null, tint = Secondary, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text(it, color = Secondary, fontSize = 13.sp) } }
    }
}

@Composable
private fun DeckRow(name: String, d: com.yokayo.music.audio.DeckInfo) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        CoverView(d.cover, Modifier.size(52.dp).alpha(0.4f + 0.6f * d.level.coerceIn(0f, 1f)), corner = 8.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text("$name · ${d.title}", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                d.bpm?.let { Text("%.1f BPM".format(it), color = Neon, fontSize = 12.sp) }
                d.key?.let { Text(it, color = Secondary, fontSize = 12.sp) }
                d.filter?.let { Text(it, color = Color(0xFFFF9F0A), fontSize = 12.sp, maxLines = 1) }
            }
            Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Fill)) {
                Box(Modifier.fillMaxWidth(d.level.coerceIn(0f, 1f)).fillMaxHeight().background(Brush.horizontalGradient(listOf(Neon, NeonDeep))))
            }
        }
    }
}

/** Оценка перехода: 👍/👎 учат ИИ-композитора. */
@Composable
private fun RateMix(r: MixComposer.Recipe, modifier: Modifier) {
    var rated by remember(r) { mutableStateOf<Boolean?>(null) }
    Row(modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.06f)).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(if (rated == null) "Как переход?" else "Запомнил, спасибо", color = Color.White, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        listOf(true, false).forEach { good ->
            Box(Modifier.padding(start = 10.dp).size(48.dp, 40.dp).clip(RoundedCornerShape(12.dp))
                .background(if (rated == good) Neon.copy(alpha = 0.35f) else Color.White.copy(alpha = 0.08f))
                .clickable(enabled = rated == null) { MixBrain.learn(r, good, 1.5); rated = good }, contentAlignment = Alignment.Center) {
                Icon(if (good) Icons.Default.ThumbUp else Icons.Default.ThumbDown, null, tint = Color.White)
            }
        }
    }
}

/** Выбор трека: поиск или «Мне нравится». */
@Composable
private fun TrackPicker(state: AppState, close: () -> Unit, pick: (Track) -> Unit) {
    var q by remember { mutableStateOf("") }
    var list by remember { mutableStateOf<List<Track>>(emptyList()) }
    LaunchedEffect(q) {
        delay(if (q.isBlank()) 0 else 350)
        list = runCatching { if (q.isBlank()) state.cached("liked") { Ym.liked() } else Ym.search(q).tracks }.getOrDefault(emptyList())
    }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f)).clickable(onClick = close)) {
        Column(Modifier.fillMaxSize().padding(top = 60.dp).clip(RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)).background(Color(0xFF111426)).clickable(enabled = false) {}) {
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Выбери трек", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 20.sp, modifier = Modifier.weight(1f))
                Text("Отмена", color = Neon, modifier = Modifier.clickable(onClick = close))
            }
            Row(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(40.dp).clip(RoundedCornerShape(12.dp)).background(Color(0x3D767680)).padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Search, null, tint = Secondary, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(6.dp))
                Box(Modifier.weight(1f)) {
                    if (q.isEmpty()) Text("Поиск или «Мне нравится»", color = Secondary, fontSize = 17.sp)
                    BasicTextField(q, { q = it }, singleLine = true, textStyle = TextStyle(color = Color.White, fontSize = 17.sp), cursorBrush = SolidColor(Neon), modifier = Modifier.fillMaxWidth())
                }
            }
            LazyColumn(contentPadding = PaddingValues(vertical = 8.dp)) {
                items(list) { t ->
                    Row(Modifier.fillMaxWidth().clickable { pick(t) }.padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        CoverView(t.coverUrl(100), Modifier.size(48.dp), corner = 5.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(t.title, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(t.artist, color = Secondary, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Analyzer.cached(t.id)?.let { Text("${it.bpm.toInt()} BPM", color = Neon, fontSize = 12.sp) }
                    }
                }
            }
        }
    }
}
