package com.yokayo.music

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import kotlin.math.cos
import kotlin.math.sin

val Neon = Color(0xFF5CB8FF)
val NeonDeep = Color(0xFF2961FF)
val Indigo = Color(0xFF5856D6)
val Secondary = Color(0x99EBEBF5)
val Fill = Color(0x1FFFFFFF)
val Separator = Color(0x14FFFFFF)

/** Время в секундах, обновляется каждый кадр. */
@Composable
fun frameTime(): State<Float> = produceState(0f) {
    val start = withFrameNanos { it }
    while (true) withFrameNanos { value = (it - start) / 1e9f }
}

/** Нажатие с лёгким сжатием, как PressScale на iPhone. */
fun Modifier.press(onClick: () -> Unit): Modifier = composed {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) 0.95f else 1f, spring(dampingRatio = 0.6f, stiffness = 600f), label = "press")
    this.scale(s).clickable(src, null, onClick = onClick)
}

private class P(val x: Float, val y: Float, val r: Float, val drift: Float, val phase: Float, val tw: Float, val star: Boolean)

private fun particles(count: Int): List<P> {
    var state = 7UL * 0x9E3779B97F4A7C15UL
    fun next(): Float { state = state * 6364136223846793005UL + 1442695040888963407UL; return ((state shr 11).toDouble() / (1UL shl 53).toDouble()).toFloat() }
    return List(count) { P(next(), next(), 0.6f + next() * 2.2f, 0.004f + next() * 0.012f, next() * 6.28f, 0.6f + next() * 1.8f, next() > 0.88f) }
}

/** Светящиеся частицы: плывут вверх, мерцают, некоторые — со звёздным бликом. */
@Composable
fun ParticleField(modifier: Modifier = Modifier, count: Int = 70, color: Color = Neon) {
    val ps = remember(count) { particles(count) }
    val time = frameTime()
    Canvas(modifier.fillMaxSize()) {
        val t = time.value
        val k = density
        for (p in ps) {
            var y = (p.y - t * p.drift) % 1f; if (y < 0) y += 1f
            val yy = y * (size.height + 40 * k) - 20 * k
            val xx = p.x * size.width + sin(t * 0.3f + p.phase) * 18 * k
            val a = 0.25f + 0.75f * (0.5f + 0.5f * sin(t * p.tw + p.phase))
            val r = p.r * k
            drawCircle(color.copy(alpha = 0.10f * a), r * 3, Offset(xx, yy))
            drawCircle(color.copy(alpha = 0.22f * a), r * 1.6f, Offset(xx, yy))
            drawCircle(Color.White.copy(alpha = 0.9f * a), r / 2, Offset(xx, yy))
            if (p.star) {
                drawLine(color.copy(alpha = 0.5f * a), Offset(xx - r * 5, yy), Offset(xx + r * 5, yy), 0.6f * k)
                drawLine(color.copy(alpha = 0.5f * a), Offset(xx, yy - r * 5), Offset(xx, yy + r * 5), 0.6f * k)
            }
        }
    }
}

/** Неоновые лучи фона, как на обложке бренда. */
@Composable
fun NeonRays(modifier: Modifier = Modifier) {
    val time = frameTime()
    Canvas(modifier.fillMaxSize()) {
        val t = time.value
        for (i in 0 until 4) {
            val k = i.toFloat()
            val sway = sin(t * 0.25f + k) * 30 * density
            val p = Path().apply {
                moveTo(-40f, size.height * (0.55f + 0.12f * k))
                quadraticTo(size.width * 0.35f, size.height * (0.35f + 0.05f * k) - sway, size.width + 40f, size.height * (0.1f + 0.08f * k) + sway)
            }
            drawPath(p, Neon.copy(alpha = 0.07f), style = Stroke((18 + k * 6) * density))
            drawPath(p, Neon.copy(alpha = 0.12f), style = Stroke((7 + k * 2) * density))
            drawPath(p, Neon.copy(alpha = 0.35f - k * 0.06f), style = Stroke((1.5f + k * 0.5f) * density))
        }
    }
}

/** Фирменный фон Yokayo: чёрный, неоновое сияние сверху, лучи, частицы. */
@Composable
fun YokayoBackground(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize().background(Color.Black)) {
        Canvas(Modifier.fillMaxSize()) {
            drawRect(Brush.radialGradient(listOf(NeonDeep.copy(alpha = 0.35f), Color.Transparent), Offset(size.width / 2, 0f), 420 * density))
            drawRect(Brush.radialGradient(listOf(Neon.copy(alpha = 0.12f), Color.Transparent), Offset(size.width, size.height), 380 * density))
        }
        if (Prefs.particles) {
            NeonRays(Modifier.alpha(0.35f))
            ParticleField()
        }
    }
}

/** Звезда Yokayo: свечение, лёгкое покачивание и «дыхание» (анимация — в слое, без перекомпоновки). */
@Composable
fun GlowingStar(size: Dp, modifier: Modifier = Modifier, extraRotation: Float = 0f) {
    val time = frameTime()
    Box(modifier, contentAlignment = Alignment.Center) {
        Image(painterResource(R.drawable.star), null, Modifier.size(size)
            .graphicsLayer { val b = 1f + 0.03f * sin(time.value * 1.6f); scaleX = b * 1.6f; scaleY = b * 1.6f; alpha = 0.5f }
            .blur(size / 2.5f, androidx.compose.ui.draw.BlurredEdgeTreatment.Unbounded),
            colorFilter = ColorFilter.tint(NeonDeep, androidx.compose.ui.graphics.BlendMode.SrcAtop))
        Image(painterResource(R.drawable.star), null, Modifier.size(size)
            .graphicsLayer { val t = time.value; val b = 1f + 0.03f * sin(t * 1.6f); scaleX = b * 1.25f; scaleY = b * 1.25f; alpha = 0.75f + 0.1f * sin(t * 1.6f) }
            .blur(size / 5, androidx.compose.ui.draw.BlurredEdgeTreatment.Unbounded),
            colorFilter = ColorFilter.tint(Neon, androidx.compose.ui.graphics.BlendMode.SrcAtop))
        Image(painterResource(R.drawable.star), null, Modifier.size(size)
            .graphicsLayer { val t = time.value; val b = 1f + 0.03f * sin(t * 1.6f); scaleX = b; scaleY = b; rotationZ = sin(t * 0.4f) * 6f + extraRotation })
    }
}

/** Живой фон из цветов обложки: пятна медленно плавают (замена MeshGradient). */
@Composable
fun LivingBackground(colors: List<Color>, modifier: Modifier = Modifier) {
    val time = frameTime()
    Canvas(modifier.fillMaxSize()) {
        val t = time.value
        drawRect(colors.getOrElse(4) { Color.DarkGray })
        val pts = listOf(
            0f to 0f, 0.5f + 0.15f * sin(t * 0.3f) to 0f, 1f to 0f,
            0f to 0.5f + 0.12f * cos(t * 0.25f), 0.5f + 0.2f * sin(t * 0.21f) to 0.5f + 0.2f * cos(t * 0.27f), 1f to 0.5f + 0.12f * sin(t * 0.33f),
            0f to 1f, 0.5f + 0.15f * cos(t * 0.29f) to 1f, 1f to 1f,
        )
        val r = maxOf(size.width, size.height) * 0.62f
        pts.forEachIndexed { i, (x, y) ->
            val c = colors.getOrElse(i) { Color.Gray }
            drawCircle(Brush.radialGradient(listOf(c, c.copy(alpha = 0f)), Offset(x * size.width, y * size.height), r), r, Offset(x * size.width, y * size.height))
        }
        drawRect(Color.Black.copy(alpha = 0.18f))
    }
}

fun Modifier.layerAlpha(a: Float) = this.graphicsLayer { alpha = a }

fun plural(n: Int, one: String, few: String, many: String): String {
    val n10 = n % 10; val n100 = n % 100
    return when { n10 == 1 && n100 != 11 -> one; n10 in 2..4 && n100 !in 12..14 -> few; else -> many }
}
