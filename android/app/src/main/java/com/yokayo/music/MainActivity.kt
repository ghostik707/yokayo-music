package com.yokayo.music

import android.Manifest
import android.annotation.SuppressLint
import android.os.Build
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    private val state: AppState by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (intent.getBooleanExtra("preview", false)) state.preview()
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Neon, background = Color.Black, surface = Color.Black)) {
                Surface(Modifier.fillMaxSize(), color = Color.Black) {
                    if (state.loggedIn) Root(state) else Onboarding(state)
                }
            }
        }
    }
}

// MARK: Первый запуск

@Composable
fun Onboarding(state: AppState) {
    var stage by remember { mutableIntStateOf(0) }
    var login by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { listOf(300L, 1100L, 600L, 600L).forEachIndexed { i, d -> delay(d); stage = i + 1 } }
    @Composable fun appear(k: Int) = animateFloatAsState(if (stage >= k) 1f else 0f, spring(dampingRatio = 0.8f, stiffness = 120f), label = "s$k").value

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        val a1 = appear(1)
        NeonRays(Modifier.alpha(a1)); ParticleField(Modifier.alpha(a1), count = 90)
        Column(Modifier.fillMaxSize().systemBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.weight(1f))
            GlowingStar(170.dp, Modifier.alpha(a1).then(if (a1 < 0.99f) Modifier.blur(((1 - a1) * 24).dp, androidx.compose.ui.draw.BlurredEdgeTreatment.Unbounded) else Modifier).padding(bottom = 34.dp))
            val a2 = appear(2)
            Text("Yokayo Music", fontSize = 40.sp, fontWeight = FontWeight.Black,
                style = TextStyle(brush = Brush.verticalGradient(listOf(Color.White, Neon)), shadow = Shadow(Neon.copy(alpha = 0.7f), blurRadius = 28f)),
                modifier = Modifier.alpha(a2).offset(y = ((1 - a2) * 16).dp).then(if (a2 < 0.99f) Modifier.blur(((1 - a2) * 8).dp, androidx.compose.ui.draw.BlurredEdgeTreatment.Unbounded) else Modifier))
            val a3 = appear(3)
            Column(Modifier.padding(horizontal = 36.dp).padding(top = 18.dp).alpha(a3).offset(y = ((1 - a3) * 12).dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Привет! Ты попал в Yokayo", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Text("Неофициальный клиент Яндекс.Музыки с дизайном в духе Apple Music. Твоя подписка и музыка — из Яндекса, оформление и фишки — наши.",
                    color = Color.White.copy(alpha = 0.6f), fontSize = 16.sp, textAlign = TextAlign.Center)
            }
            Spacer(Modifier.weight(1f))
            val a4 = appear(4)
            Row(Modifier.padding(horizontal = 28.dp).padding(bottom = 24.dp).alpha(a4).offset(y = ((1 - a4) * 30).dp)
                .fillMaxWidth().height(56.dp).shadow(20.dp, RoundedCornerShape(16.dp), ambientColor = Neon, spotColor = Neon)
                .clip(RoundedCornerShape(16.dp)).background(Color.White).press { login = true },
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(26.dp).clip(CircleShape).background(Color.Red), contentAlignment = Alignment.Center) {
                    Text("Я", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                }
                Spacer(Modifier.width(10.dp))
                Text("Войти с Яндекс ID", color = Color.Black, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
            }
        }
        AnimatedVisibility(login, enter = slideInVertically { it }, exit = slideOutVertically { it }) {
            BackHandler { login = false }
            LoginSheet(state) { login = false }
        }
    }
}

/** Шторка входа: страница Яндекс ID внутри приложения. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun LoginSheet(state: AppState, close: () -> Unit) {
    var loading by remember { mutableStateOf(true) }
    var reload by remember { mutableIntStateOf(0) }
    Box(Modifier.fillMaxSize().padding(top = 40.dp).clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp))) {
        YokayoBackground()
        Column(Modifier.fillMaxSize().navigationBarsPadding()) {
            Column(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 14.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp)) {
                    Box(Modifier.size(34.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f)).clickable(onClick = close), contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.Close, null, tint = Color.White, modifier = Modifier.size(20.dp))
                    }
                    Spacer(Modifier.weight(1f))
                    Box(Modifier.size(34.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f)).clickable { reload++ }, contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.Refresh, null, tint = Color.White, modifier = Modifier.size(20.dp))
                    }
                }
                GlowingStar(54.dp)
                Text("Вход в Yokayo", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Text("Войди в свой аккаунт Яндекса — подтянем подписку, плейлисты и «Мою волну».", color = Color.White.copy(alpha = 0.6f),
                    fontSize = 15.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 30.dp))
            }
            Box(Modifier.weight(1f).padding(horizontal = 12.dp).clip(RoundedCornerShape(22.dp)), contentAlignment = Alignment.Center) {
                key(reload) {
                    AndroidView(modifier = Modifier.fillMaxSize(), factory = { ctx ->
                        WebView(ctx).apply {
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            setBackgroundColor(android.graphics.Color.BLACK)
                            CookieManager.getInstance().setAcceptCookie(true)
                            fun check(url: String?): Boolean {
                                val token = url?.let { Regex("access_token=([^&]+)").find(it)?.groupValues?.get(1) } ?: return false
                                state.onLogin(token)
                                return true
                            }
                            webViewClient = object : WebViewClient() {
                                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = check(request.url.toString())
                                override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) { check(url) }
                                override fun onPageFinished(view: WebView, url: String?) { loading = false }
                            }
                            loadUrl(Ym.LOGIN_URL)
                        }
                    })
                }
                if (loading) CircularProgressIndicator(color = Color.White)
            }
            Text("Пароль вводится только на странице Яндекса. Yokayo хранит лишь токен доступа — на этом телефоне.",
                color = Color.White.copy(alpha = 0.45f), fontSize = 11.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 30.dp, vertical = 12.dp))
        }
    }
}

// MARK: Корень

@Composable
fun Root(state: AppState) {
    var player by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { while (true) { state.tick(); delay(250) } }
    BackHandler(!player && !settings && state.stacks[state.tab].size > 1) { state.pop() }

    Box(Modifier.fillMaxSize()) {
        YokayoBackground()
        Box(Modifier.fillMaxSize().statusBarsPadding()) {
            AnimatedContent(state.tab to state.stacks[state.tab].last(), transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(120)) }, label = "nav") { (_, screen) ->
                when (screen) {
                    Screen.Home -> HomeScreen(state) { settings = true }
                    Screen.Browse -> BrowseScreen(state)
                    Screen.Library -> LibraryScreen(state)
                    Screen.Search -> SearchScreen(state)
                    is Screen.PlaylistPage -> CollectionScreen(state, "pl${screen.p.uid}:${screen.p.kind}", screen.p.title, screen.p.owner, "Плейлист", screen.p.coverUrl(600)) {
                        Ym.playlistTracks(screen.p.uid, screen.p.kind)
                    }
                    is Screen.AlbumPage -> {
                        var album by remember { mutableStateOf<Album?>(null) }
                        CollectionScreen(state, "al${screen.id}", album?.title ?: screen.title, album?.artist, "Альбом" + (album?.year?.let { " · $it" } ?: ""),
                            album?.coverUrl(600) ?: screen.cover?.let { "https://" + it.replace("%%", "600x600") }, numbered = true) {
                            Ym.albumTracks(screen.id).also { album = it.first }.second
                        }
                    }
                    is Screen.ArtistPage -> ArtistScreen(state, screen.a)
                    Screen.Liked -> CollectionScreen(state, "liked", "Мне нравится", null, "Твои любимые треки", null) { Ym.liked() }
                    Screen.Chart -> CollectionScreen(state, "chartAll", "Чарт", null, "Топ сейчас", null, numbered = true) { Ym.chart() }
                    Screen.Playlists -> PlaylistsScreen(state)
                    Screen.Artists -> ArtistsScreen(state)
                    Screen.Stats -> StatsScreen(state)
                }
            }
        }

        // мини-плеер и панель вкладок, как в iOS 26
        Column(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(horizontal = 14.dp).padding(bottom = 6.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (state.current != null) MiniPlayer(state) { player = true }
            TabBar(state)
        }

        state.toast?.let { msg ->
            LaunchedEffect(msg) { delay(2200); state.toast = null }
            Text(msg, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 10.dp).shadow(10.dp, CircleShape)
                    .clip(CircleShape).background(Color(0xF0262838)).padding(horizontal = 18.dp, vertical = 11.dp))
        }

        AnimatedVisibility(player && state.current != null, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            BackHandler { player = false }
            NowPlaying(state) { player = false }
        }
        AnimatedVisibility(settings, enter = slideInVertically { it }, exit = slideOutVertically { it }) {
            BackHandler { settings = false }
            SettingsScreen(state) { settings = false }
        }
    }
}

@Composable
private fun TabBar(state: AppState) {
    val items = listOf(Triple("Главная", Icons.Default.Home, 0), Triple("Обзор", Icons.Default.GridView, 1), Triple("Медиатека", Icons.Default.LibraryMusic, 2))
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.weight(1f).height(64.dp).shadow(16.dp, CircleShape).clip(CircleShape).background(Color(0xE61B1D29))
            .border(1.dp, Color.White.copy(alpha = 0.08f), CircleShape).padding(4.dp)) {
            items.forEach { (label, icon, i) -> TabItem(label, icon, state.tab == i, Modifier.weight(1f)) { tap(state, i) } }
        }
        Box(Modifier.size(64.dp).shadow(16.dp, CircleShape).clip(CircleShape).background(if (state.tab == 3) Color(0xFF2E3142) else Color(0xE61B1D29))
            .border(1.dp, Color.White.copy(alpha = 0.08f), CircleShape).clickable { tap(state, 3) }, contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Search, null, tint = if (state.tab == 3) Neon else Color.White, modifier = Modifier.size(28.dp))
        }
    }
}

/** Повторное нажатие на вкладку — к её началу. */
private fun tap(state: AppState, i: Int) {
    if (state.tab == i) state.stacks[i].let { while (it.size > 1) it.removeAt(it.lastIndex) }
    state.tab = i
}

@Composable
private fun TabItem(label: String, icon: ImageVector, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Column(modifier.fillMaxHeight().clip(CircleShape).background(if (selected) Color.White.copy(alpha = 0.10f) else Color.Transparent).clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(icon, null, tint = if (selected) Neon else Color.White, modifier = Modifier.size(26.dp))
        Text(label, color = if (selected) Neon else Color.White, fontSize = 11.sp, fontWeight = FontWeight.Medium)
    }
}
