package dev.localdrop.feature.transfer

import android.content.Context
import android.text.format.Formatter
import dev.localdrop.R
import dev.localdrop.core.discovery.DiscoveryBlocker
import dev.localdrop.core.protocol.ErrorCode
import dev.localdrop.core.transfer.TransferProgress
import dev.localdrop.core.transfer.TransferSummary
import dev.localdrop.core.transport.ConnectionException
import kotlin.math.ceil

/** User-facing wording shared by the in-app screen and the notifications. */
object TransferText {

    fun error(context: Context, error: ConnectionException, peer: String): String = when (error) {
        is ConnectionException.NoLocalNetwork -> context.getString(R.string.error_no_wifi)
        is ConnectionException.NotNearby -> context.getString(R.string.error_not_nearby, peer)
        is ConnectionException.NearbyButUnresponsive -> context.getString(R.string.error_nearby_unresponsive, peer)
        is ConnectionException.BluetoothUnavailable -> when (error.blocker) {
            DiscoveryBlocker.BluetoothOff -> context.getString(R.string.error_bluetooth_off)
            DiscoveryBlocker.LocationOff -> context.getString(R.string.blocker_location_off_body)
            is DiscoveryBlocker.PermissionsMissing -> context.getString(R.string.error_bluetooth_permission)
            DiscoveryBlocker.BluetoothLeUnsupported -> context.getString(R.string.blocker_unsupported_body)
            null -> context.getString(R.string.error_bluetooth_failed)
        }
        is ConnectionException.Refused -> context.getString(R.string.error_refused, peer)
        is ConnectionException.Unreachable -> context.getString(R.string.error_unreachable, peer)
        is ConnectionException.Timeout -> context.getString(R.string.error_timeout, peer)
        is ConnectionException.ConnectionLost -> context.getString(R.string.error_connection_lost, peer)
        is ConnectionException.ClosedByPeer -> context.getString(R.string.error_closed_by_peer, peer)
        is ConnectionException.IncompatibleVersion -> context.getString(R.string.error_incompatible, peer)
        is ConnectionException.AuthenticationFailed -> context.getString(R.string.error_auth_failed, peer)
        is ConnectionException.DecryptionFailed -> context.getString(R.string.error_decryption, peer)
        is ConnectionException.ProtocolViolation -> context.getString(R.string.error_protocol, peer)
        is ConnectionException.IdentityUnavailable -> context.getString(R.string.error_identity)
        is ConnectionException.PairingRejected -> context.getString(R.string.error_pairing_rejected, peer)
        is ConnectionException.StorageFailed -> context.getString(R.string.error_storage)
        is ConnectionException.SaveFailed -> context.getString(R.string.error_save_failed, error.fileName)
        is ConnectionException.NotEnoughSpace -> context.getString(R.string.error_phone_space, Formatter.formatShortFileSize(context, error.needed))
        is ConnectionException.CancelledByPeer -> context.getString(R.string.transfer_cancelled_by_peer, peer)
        is ConnectionException.SourceUnavailable -> context.getString(R.string.error_source_unavailable, error.fileName)
        is ConnectionException.TransferRejected -> when (error.reason) {
            "declined" -> context.getString(R.string.error_rejected_declined, peer)
            "busy" -> context.getString(R.string.error_rejected_busy, peer)
            "asleep" -> context.getString(R.string.error_rejected_asleep, peer)
            "insufficient_storage" -> context.getString(R.string.error_rejected_storage, peer)
            "timeout" -> context.getString(R.string.error_rejected_timeout, peer)
            else -> context.getString(R.string.error_rejected_other, peer, error.reason)
        }
        is ConnectionException.ReceiverFailed -> when (error.code) {
            ErrorCode.CHECKSUM_MISMATCH -> context.getString(R.string.error_checksum, error.fileName ?: "")
            ErrorCode.INSUFFICIENT_STORAGE -> context.getString(R.string.error_rejected_storage, peer)
            ErrorCode.WRITE_FAILED -> context.getString(R.string.error_write_failed, peer)
            else -> context.getString(R.string.error_peer_generic, peer, error.code)
        }
        is ConnectionException.PeerError -> when (error.code) {
            ErrorCode.BUSY -> context.getString(R.string.error_peer_busy, peer)
            ErrorCode.PAIRING_TIMEOUT -> context.getString(R.string.error_peer_timeout, peer)
            ErrorCode.AUTH_FAILED -> context.getString(R.string.error_peer_auth_failed, peer)
            ErrorCode.NOT_TRUSTED -> context.getString(R.string.error_peer_not_trusted, peer)
            ErrorCode.PAIRING_UNAVAILABLE -> context.getString(R.string.error_pairing_unavailable, peer)
            else -> context.getString(R.string.error_peer_generic, peer, error.code)
        }
    }

    /** "IMG_2841.jpg · 42 MB" or "3 files · 1.2 GB" */
    fun summaryLine(context: Context, summary: TransferSummary): String {
        val what = if (summary.fileCount == 1) {
            summary.firstFileName
        } else {
            context.resources.getQuantityString(R.plurals.notification_files, summary.fileCount, summary.fileCount)
        }
        return "$what · ${Formatter.formatShortFileSize(context, summary.totalBytes)}"
    }

    /** "IMG_2841.jpg · 42 MB of 428 MB · 12 MB/s" */
    fun progressLine(context: Context, progress: TransferProgress): String {
        val name = if (progress.fileCount > 1) {
            context.getString(R.string.transfer_file_of, progress.currentFileName, progress.fileIndex + 1, progress.fileCount)
        } else {
            progress.currentFileName
        }
        val bytes = context.getString(
            R.string.transfer_bytes,
            Formatter.formatShortFileSize(context, progress.bytesSent),
            Formatter.formatShortFileSize(context, progress.totalBytes),
        )
        val speed = if (progress.bytesPerSecond > 0) {
            " · " + context.getString(R.string.transfer_speed, Formatter.formatShortFileSize(context, progress.bytesPerSecond))
        } else {
            ""
        }
        val left = timeLeft(context, progress)?.let { " · $it" }.orEmpty()
        return "$name · $bytes$speed$left"
    }

    /**
     * Roughly how long the transfer still takes, from its recent speed, rounded up so the number
     * doesn't jitter: whole seconds up to 10, steps of 5 seconds up to a minute, then minutes and
     * seconds in steps of 15 (so it moves about every 15 seconds), from an hour hours and minutes.
     * Null while unknown.
     */
    fun timeLeft(context: Context, progress: TransferProgress): String? {
        val remaining = progress.totalBytes - progress.bytesSent
        if (progress.averageBytesPerSecond <= 0 || remaining <= 0) return null
        val seconds = remaining.toDouble() / progress.averageBytesPerSecond
        val step = when {
            seconds < 10 -> 1
            seconds < 60 -> 5
            seconds < 3600 -> 15
            else -> 60
        }
        val rounded = maxOf(1, (ceil(seconds / step) * step).toInt())
        return when {
            rounded < 60 -> context.getString(R.string.transfer_seconds_left, rounded)
            rounded < 3600 && rounded % 60 != 0 -> context.getString(R.string.transfer_minutes_seconds_left, rounded / 60, rounded % 60)
            rounded < 3600 -> context.getString(R.string.transfer_minutes_left, rounded / 60)
            else -> context.getString(R.string.transfer_hours_minutes_left, rounded / 3600, rounded % 3600 / 60)
        }
    }
}
