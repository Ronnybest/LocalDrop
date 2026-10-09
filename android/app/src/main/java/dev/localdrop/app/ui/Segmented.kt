package dev.localdrop.app.ui

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ListItemColors
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.ListItemShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Rows of a Material 3 Expressive segmented group: together they read as one rounded block,
 * large corners at its ends, small ones where rows meet, a hairline gap between them.
 */
object Segments {
    val Outer = 24.dp
    val Inner = 4.dp
    val Gap = 2.dp
}

/** The shape of row [index] of [count]; when rows come and go, the group's ends round again. */
@Composable
fun segmentShape(index: Int, count: Int): Shape {
    val spec = MaterialTheme.motionScheme.fastSpatialSpec<Dp>()
    val top by animateDpAsState(if (index == 0) Segments.Outer else Segments.Inner, spec, label = "top")
    val bottom by animateDpAsState(if (index == count - 1) Segments.Outer else Segments.Inner, spec, label = "bottom")
    return RoundedCornerShape(topStart = top, topEnd = top, bottomStart = bottom, bottomEnd = bottom)
}

/** Rows in the same tone as the cards around them, so a group reads as one block. */
@Composable
fun segmentColors(): ListItemColors = ListItemDefaults.segmentedColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh)

/** A segment's shape at rest, and fully rounded while pressed: the pressed row pulls loose. */
@Composable
fun segmentShapes(shape: Shape): ListItemShapes =
    ListItemDefaults.shapes(shape = shape, pressedShape = RoundedCornerShape(Segments.Outer))
