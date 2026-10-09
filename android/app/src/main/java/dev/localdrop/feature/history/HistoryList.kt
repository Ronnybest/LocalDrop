package dev.localdrop.feature.history

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItemShapes
import androidx.compose.material3.SegmentedListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import dev.localdrop.app.ui.SwipeChain
import kotlinx.coroutines.launch
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import dev.localdrop.app.ui.segmentColors
import dev.localdrop.app.ui.segmentShape
import dev.localdrop.app.ui.segmentShapes
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.localdrop.R
import dev.localdrop.core.history.HistoryEntry
import dev.localdrop.feature.devices.RoundIcon
import dev.localdrop.feature.settings.Haptic
import dev.localdrop.feature.settings.rememberHaptics

/**
 * Recent transfers as one segmented group whose rows move as a linked whole (see SwipeChain):
 * the swiped row follows the finger, its neighbours are pulled along and round the corners that
 * faced it, everything springs back or closes up after it. [group] tells groups on one screen apart.
 */
fun LazyListScope.historyGroup(
    entries: List<HistoryEntry>,
    group: String,
    chain: SwipeChain,
    onOpen: (HistoryEntry) -> Unit,
    onDelete: (HistoryEntry) -> Unit,
) {
    itemsIndexed(entries, key = { _, entry -> entry.id }) { index, entry ->
        HistoryItem(
            entry = entry,
            index = index,
            count = entries.size,
            group = group,
            chain = chain,
            onOpen = { onOpen(entry) },
            onDelete = { onDelete(entry) },
            modifier = Modifier.animateItem(),
        )
    }
}

/**
 * A recent transfer: what, from or to which Mac, when. Tapping opens it (see HistoryActions);
 * swiping it away to either side deletes it from the history, not the file.
 */
@Composable
private fun HistoryItem(
    entry: HistoryEntry,
    index: Int,
    count: Int,
    group: String,
    chain: SwipeChain,
    onOpen: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier,
) {
    val haptic = rememberHaptics()
    val scope = rememberCoroutineScope()
    var width by remember { mutableIntStateOf(0) }
    val dragged = chain.draggedId == entry.id
    val sameGroup = chain.draggedId != null && chain.group == group
    val progress = chain.progress

    // Neighbours follow the pull on a soft spring: they lag a little and settle with a wobble.
    val follow by animateFloatAsState(
        chain.pullFor(group, index),
        spring(dampingRatio = 0.5f, stiffness = Spring.StiffnessMediumLow),
        label = "follow",
    )
    val shape = segmentShape(
        index = index,
        count = count,
        loosen = if (dragged) progress else 0f,
        roundTop = if (sameGroup && chain.index == index - 1) progress * 0.8f else 0f,
        roundBottom = if (sameGroup && chain.index == index + 1) progress * 0.8f else 0f,
    )
    val dragState = rememberDraggableState { delta -> chain.drag(entry.id, delta) { haptic(Haptic.THRESHOLD) } }
    Box(
        modifier
            .onSizeChanged { width = it.width }
            .graphicsLayer { alpha = if (chain.removedId == entry.id) 0f else 1f }
            .draggable(
                state = dragState,
                orientation = Orientation.Horizontal,
                onDragStarted = { chain.start(entry.id, group, index, width) },
                onDragStopped = { velocity -> scope.launch { chain.release(entry.id, velocity, onDelete) } },
            ),
    ) {
        if (dragged) {
            // What letting go does, revealed under the row as it moves.
            val start = chain.offset > 0
            Box(
                Modifier.matchParentSize().graphicsLayer { alpha = progress.coerceAtLeast(0.15f) }.clip(shape)
                    .background(MaterialTheme.colorScheme.errorContainer).padding(horizontal = 24.dp),
                contentAlignment = if (start) Alignment.CenterStart else Alignment.CenterEnd,
            ) {
                Icon(Icons.Default.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.onErrorContainer)
            }
        }
        Box(Modifier.graphicsLayer { translationX = if (dragged) chain.offset else follow }) {
            HistoryRow(entry, segmentShapes(shape), onOpen)
        }
    }
}

@Composable
private fun HistoryRow(entry: HistoryEntry, shapes: ListItemShapes, onClick: () -> Unit) {
    val title = when {
        entry.kind == HistoryEntry.Kind.FILES && entry.count > 1 -> pluralStringResource(R.plurals.notification_files, entry.count, entry.count)
        entry.kind == HistoryEntry.Kind.TEXT && entry.title.isBlank() -> stringResource(R.string.history_text)
        // The scheme says nothing; without it more of the address fits.
        entry.kind == HistoryEntry.Kind.LINK -> entry.title.removePrefix("https://").removePrefix("http://")
        else -> entry.title
    }
    val visual = entry.mimeType?.startsWith("image/") == true || entry.mimeType?.startsWith("video/") == true
    // Sent files can't be opened again: their source was only lent to LocalDrop for the send.
    val canOpen = entry.incoming || entry.kind != HistoryEntry.Kind.FILES
    val leading: @Composable () -> Unit = {
        RoundIcon(
            size = 40,
            shape = RoundedCornerShape(12.dp),
            tint = if (visual) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHighest,
        ) {
            Icon(
                painterResource(
                    when {
                        entry.kind == HistoryEntry.Kind.LINK -> R.drawable.ic_link
                        entry.kind == HistoryEntry.Kind.TEXT -> R.drawable.ic_text
                        visual -> R.drawable.ic_image
                        else -> R.drawable.ic_file
                    },
                ),
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = if (visual) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    val supporting: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(
                painterResource(if (entry.incoming) R.drawable.ic_download else R.drawable.ic_upload),
                contentDescription = stringResource(if (entry.incoming) R.string.history_received else R.string.history_sent),
                modifier = Modifier.size(16.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(entry.peerName, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
    val trailing: @Composable () -> Unit = { Text(shortTime(entry.timeMs), style = MaterialTheme.typography.labelMedium) }
    val headline: @Composable () -> Unit = { Text(title, maxLines = 2, overflow = TextOverflow.MiddleEllipsis) }
    if (canOpen) {
        SegmentedListItem(
            onClick = onClick,
            shapes = shapes,
            colors = segmentColors(),
            leadingContent = leading,
            supportingContent = supporting,
            trailingContent = trailing,
            content = headline,
        )
    } else {
        SegmentedListItem(
            shapes = shapes,
            colors = segmentColors(),
            leadingContent = leading,
            supportingContent = supporting,
            trailingContent = trailing,
            content = headline,
        )
    }
}

/** "16:27" today, "Yesterday", then "9 Oct". */
@Composable
private fun shortTime(timeMs: Long): String {
    val context = LocalContext.current
    val now = System.currentTimeMillis()
    return when {
        DateUtils.isToday(timeMs) -> DateUtils.formatDateTime(context, timeMs, DateUtils.FORMAT_SHOW_TIME)
        DateUtils.isToday(timeMs + DateUtils.DAY_IN_MILLIS) ->
            DateUtils.getRelativeTimeSpanString(timeMs, now, DateUtils.DAY_IN_MILLIS).toString()
        else -> DateUtils.formatDateTime(context, timeMs, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_NO_YEAR)
    }
}

