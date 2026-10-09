package dev.localdrop.app.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier

/** Material 3 Expressive's wavy bar; [progress] null is indeterminate. Moves with the theme's springs. */
@Composable
fun WavyProgress(progress: Float?, modifier: Modifier = Modifier) {
    if (progress == null) {
        LinearWavyProgressIndicator(modifier.fillMaxWidth())
        return
    }
    val shown by animateFloatAsState(progress.coerceIn(0f, 1f), MaterialTheme.motionScheme.slowEffectsSpec(), label = "progress")
    LinearWavyProgressIndicator(progress = { shown }, modifier = modifier.fillMaxWidth())
}
