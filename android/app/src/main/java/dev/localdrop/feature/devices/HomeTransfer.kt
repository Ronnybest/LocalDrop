package dev.localdrop.feature.devices

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.localdrop.R
import dev.localdrop.core.history.HistoryEntry
import dev.localdrop.app.ui.WavyProgress
import dev.localdrop.core.transfer.TransferProgress
import dev.localdrop.core.transfer.TransferState
import dev.localdrop.feature.transfer.TransferText

/**
 * A session with this Mac, inside its card: the same words as the notification (what, the time
 * left) over a wavy bar, or the Mac's request to accept.
 */
@Composable
internal fun TransferInCard(state: TransferState, onCancel: () -> Unit, onAccept: () -> Unit, onDecline: () -> Unit) {
    val context = LocalContext.current
    when (state) {
        is TransferState.AwaitingLocalDecision -> {
            Lines(
                TransferText.what(context, state.summary.fileCount, state.summary.firstFileName),
                stringResource(R.string.notification_incoming_text, Formatter.formatShortFileSize(context, state.summary.totalBytes)),
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onDecline, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.action_decline)) }
                Button(onClick = onAccept, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.action_accept)) }
            }
            return
        }
        is TransferState.Transferring -> Progress(state.progress, onCancel)
        is TransferState.Receiving -> Progress(state.progress, onCancel)
        is TransferState.AwaitingApproval -> Waiting(
            TransferText.what(context, state.summary.fileCount, state.summary.firstFileName),
            stringResource(R.string.notification_awaiting_mac),
            onCancel,
        )
        is TransferState.Verifying -> Waiting(
            TransferText.what(context, state.progress.fileCount, state.progress.currentFileName),
            stringResource(R.string.transfer_verifying),
            onCancel,
        )
        is TransferState.Connecting -> Waiting(stringResource(R.string.notification_connecting), null, onCancel)
        is TransferState.Preparing -> Waiting(stringResource(R.string.transfer_preparing), null, onCancel)
        else -> Unit
    }
}

/** The time left as the card's big number, and what goes under it. */
@Composable
private fun Progress(progress: TransferProgress, onCancel: () -> Unit) {
    val context = LocalContext.current
    val fraction = if (progress.totalBytes > 0) progress.bytesSent.toFloat() / progress.totalBytes else 0f
    val left = TransferText.timeLeftShort(context, progress)
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            left ?: "${(fraction * 100).toInt()}%",
            style = MaterialTheme.typography.displaySmallEmphasized,
            color = MaterialTheme.colorScheme.primary,
        )
        val what = TransferText.what(context, progress.fileCount, progress.currentFileName)
        val detail = listOfNotNull(
            stringResource(R.string.card_left).takeIf { left != null },
            if (progress.fileCount > 1) stringResource(R.string.notification_file_index, progress.fileIndex + 1, progress.fileCount) else what,
        ).joinToString(" · ")
        Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
    }
    WavyProgress(fraction)
    FilledTonalButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.action_cancel)) }
}

/** Connecting, waiting for the Mac, checking: the expressive loading indicator beside the words. */
@Composable
private fun Waiting(title: String, detail: String?, onCancel: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        LoadingIndicator(Modifier.size(48.dp))
        Lines(title, detail)
    }
    FilledTonalButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.action_cancel)) }
}

/** A transfer of files that just finished: "Sent" or "Received", big, with what and how long. */
@Composable
internal fun FinishedInCard(entry: HistoryEntry) {
    val context = LocalContext.current
    val what = TransferText.what(context, entry.count, entry.title)
    val size = entry.bytes?.let { Formatter.formatShortFileSize(context, it) }
    val detail = when {
        size != null && entry.durationMs != null -> stringResource(R.string.card_finished_in, what, size, TransferText.duration(context, entry.durationMs))
        size != null -> stringResource(R.string.card_finished, what, size)
        else -> what
    }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            stringResource(if (entry.incoming) R.string.history_received else R.string.history_sent),
            style = MaterialTheme.typography.headlineMediumEmphasized,
            color = MaterialTheme.colorScheme.primary,
        )
        Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.MiddleEllipsis)
    }
}

@Composable
private fun Lines(title: String, detail: String?) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
        if (detail != null) Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
