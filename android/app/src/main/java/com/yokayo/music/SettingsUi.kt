package com.yokayo.music

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import java.io.File

private val Orange = Color(0xFFFF9F0A)
private val Pink = Color(0xFFFF375F)
private val Purple = Color(0xFFBF5AF2)
private val Mint = Color(0xFF63E6BE)
private val Teal = Color(0xFF30B0C7)
private val Cyan = Color(0xFF32ADE6)
private val Red = Color(0xFFFF453A)
private val Blue = Color(0xFF0A84FF)
private val Gray = Color(0xFF8E8E93)

/** Настройки: профиль, быстрые плитки и стеклянные карточки по темам. */
@Composable
fun SettingsScreen(state: AppState, close: () -> Unit) {
    var page by remember { mutableStateOf("main") }
    var confirmLogout by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    val ctx = LocalContext.current
    var cacheMb by remember { mutableLongStateOf(0) }
    LaunchedEffect(page) { cacheMb = File(ctx.cacheDir.path).walkTopDown().sumOf { it.length() } / (1024 * 1024) }

    Box(Modifier.fillMaxSize()) {
        YokayoBackground()
        Column(Modifier.fillMaxSize().systemBarsPadding()) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
                if (page != "main") Box(Modifier.align(Alignment.CenterStart)) { CircleButton(Icons.Default.ChevronLeft) { page = "main" } }
                Text(when (page) { "eq" -> "Эквалайзер"; "stats" -> "Статистика"; else -> "Настройки" }, color = Color.White, fontWeight = FontWeight.SemiBold,
                    fontSize = 17.sp, modifier = Modifier.align(Alignment.Center))
                Text("Готово", color = Neon, fontWeight = FontWeight.SemiBold, fontSize = 17.sp,
                    modifier = Modifier.align(Alignment.CenterEnd).clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).clickable(onClick = close)
                        .padding(horizontal = 16.dp, vertical = 9.dp))
            }
            when (page) {
                "eq" -> EqualizerScreen()
                "stats" -> StatsBody(state)
                else -> Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 30.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                    ProfileCard(state) { confirmLogout = true }
                    StatsStrip(state) { page = "stats" }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        QuickTile(Icons.Default.Tune, "Эквалайзер", Prefs.eqPreset.title, listOf(Mint, Teal), Prefs.eqPreset != EqPreset.FLAT, Modifier.weight(1f)) { page = "eq" }
                        QuickTile(Icons.Default.BarChart, "Статистика", "Твоя музыка", listOf(Orange, Pink), false, Modifier.weight(1f)) { page = "stats" }
                    }
                    SCard("Звук", Icons.Default.GraphicEq, Mint) {
                        SNavRow(Icons.Default.Tune, Mint, "Эквалайзер", Prefs.eqPreset.title) { page = "eq" }
                    }
                    SCard("Качество", Icons.Default.Wifi, Blue) {
                        SRow(Icons.Default.Wifi, Blue, "Wi-Fi", below = { Segmented(listOf(128, 192, 320), Prefs.qualityWifi) { Prefs.qualityWifi = it; Prefs.save() } })
                        SRow(Icons.Default.SignalCellularAlt, Color(0xFF30D158), "Мобильная сеть", below = { Segmented(listOf(128, 192, 320), Prefs.qualityCell) { Prefs.qualityCell = it; Prefs.save() } })
                        SFooter("Качество выбирается само по типу сети. 320 кбит/с — максимум Яндекса для mp3.")
                    }
                    SCard("Экран и плеер", Icons.Default.Smartphone, Cyan) {
                        SToggleRow(Icons.Default.AutoAwesome, Cyan, "Частицы на фоне", Prefs.particles) { Prefs.particles = it; Prefs.save() }
                        SToggleRow(Icons.Default.Explicit, Red, "Контент 18+", Prefs.explicit) { Prefs.explicit = it; Prefs.save() }
                    }
                    SCard("Хранилище", Icons.Default.Storage, Gray) {
                        SRow(Icons.Default.Storage, Gray, "Кэш прослушивания", trailing = {
                            Text("Очистить", color = if (cacheMb > 0) Neon else Secondary, fontWeight = FontWeight.SemiBold, fontSize = 15.sp,
                                modifier = Modifier.clickable(enabled = cacheMb > 0) { confirmClear = true })
                        })
                        SFooter("Кэш — $cacheMb МБ.")
                    }
                    About()
                }
            }
        }
    }
    if (confirmLogout) AlertDialog({ confirmLogout = false }, containerColor = Color(0xFF1E2033),
        title = { Text("Выйти из аккаунта Яндекса?", color = Color.White) },
        confirmButton = { TextButton({ confirmLogout = false; close(); state.logout() }) { Text("Выйти", color = Red) } },
        dismissButton = { TextButton({ confirmLogout = false }) { Text("Отмена", color = Neon) } })
    if (confirmClear) AlertDialog({ confirmClear = false }, containerColor = Color(0xFF1E2033),
        title = { Text("Очистить кэш прослушивания?", color = Color.White) },
        text = { Text("Треки скачаются заново при прослушивании.", color = Secondary) },
        confirmButton = { TextButton({ confirmClear = false; ctx.cacheDir.listFiles()?.forEach { it.deleteRecursively() }; cacheMb = 0 }) { Text("Очистить", color = Red) } },
        dismissButton = { TextButton({ confirmClear = false }) { Text("Отмена", color = Neon) } })
}

@Composable
private fun ProfileCard(state: AppState, onLogout: () -> Unit) {
    val acc = state.account
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(26.dp)).background(Color.White.copy(alpha = 0.08f))
        .border(1.dp, Neon.copy(alpha = 0.25f), RoundedCornerShape(26.dp)).padding(vertical = 22.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.size(104.dp).shadow(18.dp, CircleShape, ambientColor = Neon, spotColor = Neon).clip(CircleShape)
            .background(Brush.sweepGradient(listOf(Neon, NeonDeep, Purple, Neon))), contentAlignment = Alignment.Center) {
            Box(Modifier.size(92.dp).clip(CircleShape).background(Color.Black), contentAlignment = Alignment.Center) {
                if (acc?.avatar != null) AsyncImage(acc.avatar, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                else Image(painterResource(R.drawable.star), null, Modifier.padding(16.dp))
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(acc?.name?.ifEmpty { null } ?: "Аккаунт Яндекса", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            if (!acc?.login.isNullOrEmpty()) Text("@" + acc!!.login, color = Secondary, fontSize = 15.sp)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val plus = acc?.plus == true
            Row(Modifier.clip(CircleShape).background(if (plus) Brush.horizontalGradient(listOf(Orange, Pink, Purple)) else Brush.horizontalGradient(listOf(Fill, Fill)))
                .padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(if (plus) Icons.Default.AddCircle else Icons.Default.RemoveCircleOutline, null, tint = Color.White, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(if (plus) "Плюс активен" else "Без Плюса", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            }
            Text("Выйти", color = Red, fontWeight = FontWeight.SemiBold, fontSize = 15.sp,
                modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).clickable(onClick = onLogout).padding(horizontal = 14.dp, vertical = 8.dp))
        }
    }
}

@Composable
private fun StatsStrip(state: AppState, onClick: () -> Unit) {
    val week = (state.stats.totals(7).values.sum() / 60).toInt()
    val streak = state.stats.streak
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.06f)).clickable(onClick = onClick).padding(vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        @Composable fun stat(v: String, c: String) = Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(v, color = Neon, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Text(c, color = Secondary, fontSize = 11.sp, maxLines = 1)
        }
        stat("$week", "минут за неделю")
        Box(Modifier.size(1.dp, 30.dp).background(Color.White.copy(alpha = 0.15f)))
        stat("$streak", plural(streak, "день подряд", "дня подряд", "дней подряд"))
        Box(Modifier.size(1.dp, 30.dp).background(Color.White.copy(alpha = 0.15f)))
        stat("${state.liked.size}", "в «Мне нравится»")
    }
}

@Composable
private fun QuickTile(icon: ImageVector, title: String, value: String, colors: List<Color>, active: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Column(modifier.clip(RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.07f))
        .border(1.dp, Color.White.copy(alpha = if (active) 0.18f else 0.06f), RoundedCornerShape(20.dp)).press(onClick).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(44.dp).shadow(if (active) 10.dp else 4.dp, RoundedCornerShape(12.dp), ambientColor = colors[0], spotColor = colors[0])
            .clip(RoundedCornerShape(12.dp)).background(Brush.linearGradient(colors)), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = Color.White, modifier = Modifier.size(24.dp))
        }
        Column {
            Text(title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(value, color = if (active) Neon else Secondary, fontSize = 12.sp, maxLines = 1)
        }
    }
}

/** Стеклянная карточка с заголовком. */
@Composable
private fun SCard(title: String, icon: ImageVector, color: Color, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.padding(start = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = color.copy(alpha = 0.9f), modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(6.dp))
            Text(title.uppercase(), color = color.copy(alpha = 0.9f), fontSize = 12.sp, fontWeight = FontWeight.Bold)
        }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.06f))
            .border(1.dp, Color.White.copy(alpha = 0.07f), RoundedCornerShape(20.dp)), content = content)
    }
}

@Composable
private fun SRow(icon: ImageVector, color: Color, title: String, subtitle: String? = null, onClick: (() -> Unit)? = null,
                 trailing: @Composable () -> Unit = {}, below: (@Composable () -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).padding(horizontal = 14.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)).background(Brush.verticalGradient(listOf(color, color.copy(alpha = 0.75f)))),
                contentAlignment = Alignment.Center) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(17.dp)) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, color = Color.White, fontSize = 17.sp)
                subtitle?.let { Text(it, color = Secondary, fontSize = 12.sp) }
            }
            trailing()
        }
        below?.let { Box(Modifier.padding(start = 42.dp)) { it() } }
    }
}

@Composable
private fun SNavRow(icon: ImageVector, color: Color, title: String, value: String?, onClick: () -> Unit) =
    SRow(icon, color, title, onClick = onClick, trailing = {
        Row(verticalAlignment = Alignment.CenterVertically) {
            value?.let { Text(it, color = Secondary, fontSize = 17.sp, maxLines = 1) }
            Icon(Icons.Default.ChevronRight, null, tint = Secondary.copy(alpha = 0.5f))
        }
    })

@Composable
private fun SToggleRow(icon: ImageVector, color: Color, title: String, value: Boolean, set: (Boolean) -> Unit) =
    SRow(icon, color, title, trailing = {
        Switch(value, set, colors = SwitchDefaults.colors(checkedTrackColor = NeonDeep, checkedThumbColor = Color.White, uncheckedTrackColor = Color(0x3D787880), uncheckedBorderColor = Color.Transparent, uncheckedThumbColor = Color.White))
    })

@Composable
private fun SFooter(text: String) = Text(text, color = Secondary, fontSize = 12.sp, modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp))

@Composable
private fun Segmented(values: List<Int>, selected: Int, set: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(Color(0x3D767680)).padding(2.dp)) {
        values.forEach { v ->
            Box(Modifier.weight(1f).clip(RoundedCornerShape(7.dp)).background(if (v == selected) Color(0xFF636366) else Color.Transparent)
                .clickable { set(v) }.padding(vertical = 6.dp), contentAlignment = Alignment.Center) {
                Text(if (v == 320) "320 кбит/с" else "$v", color = Color.White, fontSize = 13.sp, fontWeight = if (v == selected) FontWeight.SemiBold else FontWeight.Normal)
            }
        }
    }
}

@Composable
private fun About() {
    Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Image(painterResource(R.drawable.wordmark), null, Modifier.widthIn(max = 220.dp).clip(RoundedCornerShape(14.dp)))
        Text("Yokayo Music ${BuildConfig.VERSION_NAME}", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        Text("Открытый неофициальный клиент. Не связан с Яндексом. Музыка воспроизводится по вашей подписке.", color = Secondary, fontSize = 12.sp, textAlign = TextAlign.Center)
    }
}

@Composable
private fun StatsBody(state: AppState) {
    StatsScreen(state, showBack = false)
}

// MARK: Эквалайзер

/** Эквалайзер: 10 полос, пресеты и свой. Тянешь ползунок — слышно сразу. */
@Composable
fun EqualizerScreen() {
    var gains by remember { mutableStateOf(Prefs.gains) }
    fun select(p: EqPreset) { Prefs.eqPreset = p; gains = Prefs.gains; Prefs.save() }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(22.dp)) {
        Canvas(Modifier.fillMaxWidth().height(120.dp).padding(horizontal = 14.dp)) {
            val pts = gains.mapIndexed { i, g -> Offset(size.width * (i + 0.5f) / 10, size.height / 2 - g / 12 * size.height / 2 * 0.9f) }
            val path = Path().apply {
                moveTo(0f, pts[0].y); lineTo(pts[0].x, pts[0].y)
                for (i in 1 until pts.size) {
                    val a = pts[i - 1]; val b = pts[i]; val mx = (a.x + b.x) / 2
                    cubicTo(mx, a.y, mx, b.y, b.x, b.y)
                }
                lineTo(size.width, pts.last().y)
            }
            drawLine(Color.White.copy(alpha = 0.12f), Offset(0f, size.height / 2), Offset(size.width, size.height / 2), 1f)
            val fill = Path().apply { addPath(path); lineTo(size.width, size.height); lineTo(0f, size.height); close() }
            drawPath(fill, Brush.verticalGradient(listOf(Neon.copy(alpha = 0.35f), Color.Transparent)))
            drawPath(path, Brush.horizontalGradient(listOf(Neon, NeonDeep)), style = Stroke(3.dp.toPx()))
        }
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(EqPreset.entries) { p ->
                val on = p == Prefs.eqPreset
                Text(p.title, color = if (on) Color.Black else Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp,
                    modifier = Modifier.clip(CircleShape).background(if (on) Brush.horizontalGradient(listOf(Neon, NeonDeep)) else Brush.horizontalGradient(listOf(Fill, Fill)))
                        .clickable { select(p) }.padding(horizontal = 14.dp, vertical = 8.dp))
            }
        }
        Row(Modifier.fillMaxWidth().height(260.dp).padding(horizontal = 10.dp), verticalAlignment = Alignment.Bottom) {
            gains.forEachIndexed { i, g ->
                BandSlider(g, Modifier.weight(1f).fillMaxHeight(), onStart = {
                    if (Prefs.eqPreset != EqPreset.CUSTOM) { Prefs.eqCustom = gains; Prefs.eqPreset = EqPreset.CUSTOM }
                }, onEnd = { Prefs.eqCustom = gains; Prefs.save() }) { v ->
                    gains = gains.toMutableList().also { it[i] = v }
                    Engine.applyEq(gains)
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp)) {
            EqPreset.labels.forEach { Text(it, color = Secondary, fontSize = 11.sp, textAlign = TextAlign.Center, modifier = Modifier.weight(1f)) }
        }
        OutlinedButton({ select(EqPreset.FLAT) }, border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.3f))) {
            Icon(Icons.Default.Refresh, null, tint = Color.White); Spacer(Modifier.width(6.dp)); Text("Сбросить", color = Color.White)
        }
        Text("Полосы от 32 Гц (саб-бас) до 16 кГц (воздух). Свои настройки сохраняются в пресет «Свой».",
            color = Secondary, fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 24.dp))
    }
}

/** Вертикальный ползунок полосы, ±12 дБ с шагом 0,5. */
@Composable
private fun BandSlider(value: Float, modifier: Modifier, onStart: () -> Unit, onEnd: () -> Unit, set: (Float) -> Unit) {
    var h by remember { mutableIntStateOf(1) }
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text((if (value > 0) "+" else "") + (if (value % 1f == 0f) value.toInt().toString() else "%.1f".format(value)),
            color = if (value != 0f) Neon else Secondary, fontSize = 10.sp)
        Spacer(Modifier.height(6.dp))
        Box(Modifier.weight(1f).width(36.dp).onSizeChanged { h = it.height.coerceAtLeast(1) }
            .pointerInput(Unit) {
                detectVerticalDragGestures(onDragStart = { onStart() }, onDragEnd = onEnd) { ch, _ ->
                    val v = ((0.5f - ch.position.y / h) * 24f).coerceIn(-12f, 12f)
                    set((v * 2).let { kotlin.math.round(it) } / 2)
                }
            }, contentAlignment = Alignment.Center) {
            Box(Modifier.width(6.dp).fillMaxHeight().clip(CircleShape).background(Color.White.copy(alpha = 0.12f)))
            val frac = (value + 12f) / 24f
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                Box(Modifier.offset(y = with(androidx.compose.ui.platform.LocalDensity.current) { ((1 - frac) * h).toDp() - 13.dp })
                    .size(26.dp).shadow(6.dp, CircleShape, ambientColor = Neon, spotColor = Neon).clip(CircleShape).background(Color.White))
            }
        }
    }
}
