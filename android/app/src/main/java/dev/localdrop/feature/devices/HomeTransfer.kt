package dev.localdrop.feature.devices

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.localdrop.R
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

@Composable
private fun Progress(progress: TransferProgress, onCancel: () -> Unit) {
    val context = LocalContext.current
    val fraction = if (progress.totalBytes > 0) progress.bytesSent.toFloat() / progress.totalBytes else 0f
    Lines(
        TransferText.what(context, progress.fileCount, progress.currentFileName),
        if (progress.fileCount > 1) stringResource(R.string.notification_file_index, progress.fileIndex + 1, progress.fileCount) else null,
    )
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        WavyProgress(fraction)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            val bytes = stringResource(
                R.string.transfer_bytes,
                Formatter.formatShortFileSize(context, progress.bytesSent),
                Formatter.formatShortFileSize(context, progress.totalBytes),
            )
            val left = TransferText.timeLeft(context, progress)?.replaceFirstChar { it.titlecase() } ?: bytes
            Text(left, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("${(fraction * 100).toInt()}%", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    FilledTonalButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.action_cancel)) }
}

@Composable
private fun Waiting(title: String, detail: String?, onCancel: () -> Unit) {
    Lines(title, detail)
    WavyProgress(null)
    FilledTonalButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.action_cancel)) }
}

@Composable
private fun Lines(title: String, detail: String?) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
        if (detail != null) Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
