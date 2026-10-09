package dev.localdrop.app.ui

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.math.abs
import kotlin.math.sign

/**
 * One swipe shared by the rows of a segmented group, after the notification shade of Android 16
 * (whose "magnetic" rows aren't available to apps): the swiped row follows the finger and its
 * two neighbours are held to it slightly (see [pullFor]); past the delete point it comes loose —
 * the neighbours spring back, a tick — and reattaches if the finger returns. Let go short of
 * it and everything settles back; past it the row flies off and the group closes up.
 */
@Stable
class SwipeChain {
    var draggedId by mutableStateOf<String?>(null)
        private set
    var group by mutableStateOf<String?>(null)
        private set
    var index by mutableIntStateOf(-1)
        private set
    var offset by mutableFloatStateOf(0f)
        private set

    /** The row that just flew off: kept invisible while the list removes it. */
    var removedId by mutableStateOf<String?>(null)
        private set
    private var width = 1f
    private var maxPull = 0f
    private var leaving = false
    private var armed = false

    /** 0 at rest, 1 at the point where letting go deletes. */
    val progress: Float get() = if (draggedId == null) 0f else (abs(offset) / (width * DISMISS_FRACTION)).coerceIn(0f, 1f)

    fun start(id: String, group: String, index: Int, width: Int, maxPull: Float) {
        this.maxPull = maxPull
        draggedId = id
        this.group = group
        this.index = index
        this.width = width.toFloat().coerceAtLeast(1f)
        removedId = null
        leaving = false
        armed = false
    }

    /** Moves the swiped row; [onThreshold] fires once each time the delete point is crossed. */
    fun drag(id: String, delta: Float, onThreshold: () -> Unit) {
        if (draggedId != id || leaving) return
        offset += delta
        val past = abs(offset) >= width * DISMISS_FRACTION
        if (past && !armed) onThreshold()
        armed = past
    }

    /**
     * How far a neighbour of the swiped row is held along: a little, up to [maxPull]; nothing
     * once the row has come loose or for rows further away.
     */
    fun pullFor(group: String, rowIndex: Int): Float {
        if (draggedId == null || this.group != group || leaving || armed) return 0f
        if (abs(rowIndex - index) != 1) return 0f
        return (offset * NEIGHBOUR_PULL).coerceIn(-maxPull, maxPull)
    }

    suspend fun release(id: String, velocity: Float, onDismiss: () -> Unit) {
        if (draggedId != id) return
        val flung = abs(velocity) > FLING_VELOCITY && sign(velocity) == sign(offset) && abs(offset) > width * 0.1f
        if (abs(offset) >= width * DISMISS_FRACTION || flung) {
            leaving = true
            animate(offset, sign(offset) * width * 1.1f, velocity, tween(DISMISS_MS)) { value, _ -> offset = value }
            removedId = id
            onDismiss()
        } else {
            animate(offset, 0f, velocity, spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessMedium)) { value, _ -> offset = value }
        }
        draggedId = null
        offset = 0f
        leaving = false
    }

    private companion object {
        const val DISMISS_FRACTION = 0.35f
        const val NEIGHBOUR_PULL = 0.12f
        const val FLING_VELOCITY = 1_800f
        const val DISMISS_MS = 180
    }
}
