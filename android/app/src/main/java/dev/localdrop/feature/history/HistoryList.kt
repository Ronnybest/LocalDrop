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
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
 * Recent transfers as one segmented group. Rows react to each other: the one being swiped comes
 * loose and its neighbours round the corners that faced it; when it is deleted the rest close up
 * and the group's ends round again. [swiping] is the id of the row under the finger.
 */
fun LazyListScope.historyGroup(
    entries: List<HistoryEntry>,
    swiping: String?,
    onSwiping: (id: String, swiping: Boolean) -> Unit,
    onOpen: (HistoryEntry) -> Unit,
    onDelete: (HistoryEntry) -> Unit,
) {
    itemsIndexed(entries, key = { _, entry -> entry.id }) { index, entry ->
        HistoryItem(
            entry = entry,
            index = index,
            count = entries.size,
            detached = swiping == entry.id,
            roundTop = swiping != null && entries.getOrNull(index - 1)?.id == swiping,
            roundBottom = swiping != null && entries.getOrNull(index + 1)?.id == swiping,
            onSwiping = { onSwiping(entry.id, it) },
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
    detached: Boolean,
    roundTop: Boolean,
    roundBottom: Boolean,
    onSwiping: (Boolean) -> Unit,
    onOpen: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier,
) {
    val haptic = rememberHaptics()
    val state = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value != SwipeToDismissBoxValue.Settled) onDelete()
            value != SwipeToDismissBoxValue.Settled
        },
    )
    LaunchedEffect(state.dismissDirection) { onSwiping(state.dismissDirection != SwipeToDismissBoxValue.Settled) }
    // A tick the moment the swipe goes far enough to delete on release.
    LaunchedEffect(state.targetValue) {
        if (state.targetValue != SwipeToDismissBoxValue.Settled) haptic(Haptic.THRESHOLD)
    }
    val shape = segmentShape(index, count, detached, roundTop, roundBottom)
    SwipeToDismissBox(
        state = state,
        modifier = modifier,
        backgroundContent = {
            val start = state.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            Box(
                Modifier.fillMaxSize().clip(shape).background(MaterialTheme.colorScheme.errorContainer).padding(horizontal = 24.dp),
                contentAlignment = if (start) Alignment.CenterStart else Alignment.CenterEnd,
            ) {
                Icon(Icons.Default.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.onErrorContainer)
            }
        },
    ) {
        HistoryRow(entry, segmentShapes(shape), onOpen)
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

