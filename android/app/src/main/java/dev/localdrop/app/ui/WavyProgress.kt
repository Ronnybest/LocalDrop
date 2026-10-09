package dev.localdrop.app.ui

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * The wavy progress bar of Material 3 Expressive: the done part waves and flows, the rest is a
 * flat track after a gap, ending in a stop dot. [progress] null is indeterminate: a wave slides
 * along the track. (material3 1.4 has no wavy indicator yet; this draws the same shape.)
 */
@Composable
fun WavyProgress(progress: Float?, modifier: Modifier = Modifier) {
    val active = MaterialTheme.colorScheme.primary
    val track = MaterialTheme.colorScheme.secondaryContainer
    val transition = rememberInfiniteTransition(label = "wave")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(WAVE_PERIOD_MS, easing = LinearEasing)),
        label = "phase",
    )
    val slide by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(SLIDE_PERIOD_MS, easing = FastOutSlowInEasing)),
        label = "slide",
    )
    val shown by animateFloatAsState(progress?.coerceIn(0f, 1f) ?: 0f, label = "progress")

    Canvas(modifier.fillMaxWidth().height(14.dp)) {
        val stroke = 4.dp.toPx()
        val gap = 6.dp.toPx()
        val start = stroke / 2
        val end = size.width - stroke / 2
        val mid = size.height / 2
        if (progress == null) {
            val length = (end - start) * INDETERMINATE_LENGTH
            val from = start - length + (end - start + length) * slide
            val a = max(start, from)
            val b = min(end, from + length)
            flat(track, start, a - gap, stroke)
            flat(track, b + gap, end, stroke)
            if (b > a) wave(active, a, b, phase, stroke)
        } else {
            val done = start + (end - start) * shown
            flat(track, done + gap + stroke, end, stroke)
            drawCircle(active, stroke / 2, Offset(end, mid))
            if (shown > 0f) wave(active, start, done, phase, stroke)
        }
    }
}

private fun DrawScope.flat(color: androidx.compose.ui.graphics.Color, from: Float, to: Float, stroke: Float) {
    if (to <= from) return
    val mid = size.height / 2
    drawLine(color, Offset(from, mid), Offset(to, mid), stroke, StrokeCap.Round)
}

private fun DrawScope.wave(color: androidx.compose.ui.graphics.Color, from: Float, to: Float, phase: Float, stroke: Float) {
    val mid = size.height / 2
    val amplitude = 3.dp.toPx()
    val wavelength = 24.dp.toPx()
    val step = 1.dp.toPx()
    fun y(x: Float) = mid + amplitude * sin(((x / wavelength) - phase) * 2 * PI).toFloat()
    val path = Path().apply {
        var x = from
        moveTo(x, y(x))
        while (x < to) {
            x = min(x + step, to)
            lineTo(x, y(x))
        }
    }
    drawPath(path, color, style = Stroke(stroke, cap = StrokeCap.Round))
}

private const val WAVE_PERIOD_MS = 1_200
private const val SLIDE_PERIOD_MS = 1_800
private const val INDETERMINATE_LENGTH = 0.35f
