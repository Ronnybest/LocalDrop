package dev.localdrop.feature.devices

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.toPath
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.graphics.shapes.Morph
import dev.localdrop.R
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/** What a Mac's badge shows: resting, a session under way, a transfer just finished. */
enum class AvatarState { IDLE, BUSY, DONE }

/**
 * A Mac in a Material 3 Expressive shape that follows what is going on: a cookie at rest, a sun
 * slowly turning during a transfer, a circle with a check when it is done. Shapes morph into each
 * other with the theme's spring; the laptop stays upright while the sun turns.
 */
@Composable
fun MacAvatar(state: AvatarState, size: Dp = 56.dp) {
    val target = when (state) {
        AvatarState.IDLE -> MaterialShapes.Cookie9Sided
        AvatarState.BUSY -> MaterialShapes.Sunny
        AvatarState.DONE -> MaterialShapes.Circle
    }
    var from by remember { mutableStateOf(target) }
    var to by remember { mutableStateOf(target) }
    val morphProgress = remember { Animatable(1f) }
    val scale = remember { Animatable(1f) }
    val spatial = MaterialTheme.motionScheme.defaultSpatialSpec<Float>()
    val bouncy = MaterialTheme.motionScheme.fastSpatialSpec<Float>()
    LaunchedEffect(target) {
        if (target === to) return@LaunchedEffect
        from = to
        to = target
        morphProgress.snapTo(0f)
        if (state == AvatarState.DONE) scale.snapTo(0.8f)
        // Morph and the little pop of "done" run together.
        coroutineScope {
            launch { morphProgress.animateTo(1f, spatial) }
            launch { scale.animateTo(1f, bouncy) }
        }
    }
    val morph = remember(from, to) { Morph(from, to) }

    val spin = rememberInfiniteTransition(label = "spin")
    val turning by spin.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(SPIN_PERIOD_MS, easing = LinearEasing), RepeatMode.Restart),
        label = "turn",
    )
    val rotation = if (state == AvatarState.BUSY) turning else 0f

    val resting = state == AvatarState.IDLE
    val container by animateColorAsState(
        if (resting) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.primary,
        MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "container",
    )
    val content by animateColorAsState(
        if (resting) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onPrimary,
        MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "content",
    )
    Box(
        Modifier
            .size(size)
            .graphicsLayer {
                rotationZ = rotation
                scaleX = scale.value
                scaleY = scale.value
            }
            .clip(MorphShape(morph, morphProgress.value))
            .background(container),
        contentAlignment = Alignment.Center,
    ) {
        AnimatedContent(
            targetState = state == AvatarState.DONE,
            modifier = Modifier.graphicsLayer { rotationZ = -rotation },
            transitionSpec = { (fadeIn() + scaleIn(initialScale = 0.6f)) togetherWith fadeOut() },
            label = "badge",
        ) { done ->
            if (done) {
                Icon(Icons.Default.Check, contentDescription = null, tint = content, modifier = Modifier.size(size * 0.5f))
            } else {
                Icon(painterResource(R.drawable.ic_laptop), contentDescription = null, tint = content, modifier = Modifier.size(size * 0.45f))
            }
        }
    }
}

/** A morph between two Material shapes (normalized to a unit square), stretched to the size. */
private class MorphShape(private val morph: Morph, private val progress: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val path = morph.toPath(progress)
        path.transform(Matrix().apply { scale(size.width, size.height) })
        return Outline.Generic(path)
    }
}

private const val SPIN_PERIOD_MS = 6_000
