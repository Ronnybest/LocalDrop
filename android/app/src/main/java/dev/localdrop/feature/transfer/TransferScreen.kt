package dev.localdrop.feature.transfer

import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.localdrop.R
import dev.localdrop.core.transfer.TransferProgress
import dev.localdrop.core.transfer.TransferState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TransferScreen(
    state: TransferState,
    onConfirmPairing: () -> Unit,
    onDeclinePairing: () -> Unit,
    onCancel: () -> Unit,
    onDismiss: () -> Unit,
) {
    BackHandler {
        when (state) {
            is TransferState.Completed, is TransferState.Failed, is TransferState.Cancelled, is TransferState.Paired,
            is TransferState.TextCopied,
            -> onDismiss()
            is TransferState.Pairing -> onDeclinePairing()
            else -> onCancel()
        }
    }
    Scaffold(topBar = { TopAppBar(title = { Text(stringResource(R.string.app_name)) }) }) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        ) {
            when (state) {
                TransferState.Idle -> Unit
                is TransferState.Connecting -> Waiting(stringResource(R.string.transfer_connecting, state.peerName), onCancel)
                is TransferState.Pairing -> PairingContent(state, onConfirmPairing, onDeclinePairing)
                is TransferState.Preparing -> Waiting(stringResource(R.string.transfer_preparing), onCancel)
                is TransferState.AwaitingApproval -> Waiting(
                    stringResource(R.string.transfer_waiting, state.peerName),
                    onCancel,
                    detail = stringResource(R.string.transfer_waiting_detail, state.peerName),
                )
                is TransferState.Transferring -> ProgressContent(state.progress, verifying = false, onCancel)
                is TransferState.Verifying -> ProgressContent(state.progress, verifying = true, onCancel)
                is TransferState.Completed -> {
                    val context = LocalContext.current
                    Text(
                        stringResource(R.string.transfer_completed, state.peerName),
                        style = MaterialTheme.typography.titleLarge,
                        textAlign = TextAlign.Center,
                    )
                    val seconds = state.durationMs / 1000.0
                    val speed = if (state.durationMs > 0) state.summary.totalBytes * 1000 / state.durationMs else 0
                    Text(
                        stringResource(
                            R.string.transfer_completed_detail,
                            Formatter.formatShortFileSize(context, state.summary.totalBytes),
                            "%.1f".format(seconds),
                            Formatter.formatShortFileSize(context, speed),
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                    Button(onClick = onDismiss) { Text(stringResource(R.string.action_done)) }
                }
                is TransferState.TextCopied -> {
                    Text(
                        stringResource(R.string.text_copied_title, state.peerName),
                        style = MaterialTheme.typography.titleLarge,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        stringResource(R.string.text_copied_body),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                    Button(onClick = onDismiss) { Text(stringResource(R.string.action_done)) }
                }
                is TransferState.Paired -> {
                    Text(
                        stringResource(if (state.newlyPaired) R.string.paired_title else R.string.already_paired_title, state.peerName),
                        style = MaterialTheme.typography.titleLarge,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        stringResource(R.string.paired_body, state.peerName),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                    Button(onClick = onDismiss) { Text(stringResource(R.string.action_done)) }
                }
                is TransferState.Failed -> {
                    Text(stringResource(R.string.transfer_failed_title), style = MaterialTheme.typography.titleMedium)
                    Text(
                        TransferText.error(LocalContext.current, state.error, state.peerName),
                        style = MaterialTheme.typography.bodyMedium,
                        textAlign = TextAlign.Center,
                    )
                    Button(onClick = onDismiss) { Text(stringResource(R.string.action_ok)) }
                }
                is TransferState.Cancelled -> {
                    Text(
                        if (state.byPeer) {
                            stringResource(R.string.transfer_cancelled_by_peer, state.peerName)
                        } else {
                            stringResource(R.string.transfer_cancelled)
                        },
                        style = MaterialTheme.typography.titleMedium,
                        textAlign = TextAlign.Center,
                    )
                    Button(onClick = onDismiss) { Text(stringResource(R.string.action_ok)) }
                }
            }
        }
    }
}

@Composable
private fun Waiting(title: String, onCancel: () -> Unit, detail: String? = null) {
    CircularProgressIndicator()
    Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
    if (detail != null) {
        Text(
            detail,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
    OutlinedButton(onClick = onCancel) { Text(stringResource(R.string.action_cancel)) }
}

@Composable
private fun ProgressContent(progress: TransferProgress, verifying: Boolean, onCancel: () -> Unit) {
    val context = LocalContext.current
    val fraction = if (progress.totalBytes > 0) progress.bytesSent.toFloat() / progress.totalBytes else 1f
    Text(
        if (verifying) {
            stringResource(R.string.transfer_verifying)
        } else {
            stringResource(R.string.transfer_sending, Formatter.formatShortFileSize(context, progress.totalBytes))
        },
        style = MaterialTheme.typography.titleLarge,
    )
    Text(
        if (progress.fileCount > 1) {
            stringResource(R.string.transfer_file_of, progress.currentFileName, progress.fileIndex + 1, progress.fileCount)
        } else {
            progress.currentFileName
        },
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        overflow = TextOverflow.MiddleEllipsis,
    )
    if (verifying) {
        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
    } else {
        LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
    }
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(
            stringResource(
                R.string.transfer_bytes,
                Formatter.formatShortFileSize(context, progress.bytesSent),
                Formatter.formatShortFileSize(context, progress.totalBytes),
            ),
            style = MaterialTheme.typography.bodySmall,
        )
        Text("${(fraction * 100).toInt()}%", style = MaterialTheme.typography.bodySmall)
    }
    if (!verifying) {
        Text(
            stringResource(R.string.transfer_speed, Formatter.formatShortFileSize(context, progress.bytesPerSecond)),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
        )
    }
    OutlinedButton(onClick = onCancel) { Text(stringResource(R.string.action_cancel)) }
}

@Composable
private fun PairingContent(state: TransferState.Pairing, onConfirm: () -> Unit, onDecline: () -> Unit) {
    val name = state.peer.name
    Text(stringResource(R.string.pairing_title, name), style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
    if (state.keyChanged) {
        Text(
            stringResource(R.string.pairing_key_changed, name),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center,
        )
    }
    Text(
        stringResource(R.string.pairing_compare, name),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
    )
    Text(state.code, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, fontSize = 40.sp)
    if (state.confirmedLocally) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            Text(
                stringResource(R.string.pairing_waiting, name),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        OutlinedButton(onClick = onDecline) { Text(stringResource(R.string.action_cancel)) }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(onClick = onDecline) { Text(stringResource(R.string.action_decline)) }
            Button(onClick = onConfirm) { Text(stringResource(R.string.action_pair)) }
        }
    }
    Spacer(Modifier.height(8.dp))
}

