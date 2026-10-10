package dev.localdrop.feature.transfer

import android.content.Context
import android.net.Uri
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
        is ConnectionException.BlockedByVpn -> context.getString(R.string.error_vpn_blocks, peer)
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

    /** "IMG_2841.jpg" or "3 files": what a notification is about. */
    fun what(context: Context, fileCount: Int, firstFileName: String): String =
        if (fileCount == 1) firstFileName else context.resources.getQuantityString(R.plurals.notification_files, fileCount, fileCount)

    /**
     * The one line of a progress notification: "About 30 s left · 243 MB of 1 GB", or with
     * several files "About 1 min 15 s left · file 2 of 3". Speed is on the transfer screen.
     */
    fun notificationLine(context: Context, progress: TransferProgress): String {
        val left = timeLeft(context, progress)?.replaceFirstChar { it.titlecase() }
        val detail = if (progress.fileCount > 1) {
            context.getString(R.string.notification_file_index, progress.fileIndex + 1, progress.fileCount)
        } else {
            context.getString(
                R.string.transfer_bytes,
                Formatter.formatShortFileSize(context, progress.bytesSent),
                Formatter.formatShortFileSize(context, progress.totalBytes),
            )
        }
        return listOfNotNull(left, detail).joinToString(" · ")
    }

    /**
     * For the status bar chip, which has room for a few characters: "30 s", "2 min", "2 h",
     * rounded up. The notification itself shows the exact estimate. Null while unknown.
     */
    fun chipTimeLeft(context: Context, progress: TransferProgress): String? {
        val seconds = secondsLeft(progress) ?: return null
        return when {
            seconds < 60 -> context.getString(R.string.chip_seconds, seconds)
            seconds < 3600 -> context.getString(R.string.chip_minutes, (seconds + 59) / 60)
            else -> context.getString(R.string.chip_hours, (seconds + 3599) / 3600)
        }
    }

    /** "38 s", "2 min 5 s", "1 h 3 min": how long a finished transfer took. */
    fun duration(context: Context, durationMs: Long): String {
        val seconds = maxOf(1L, (durationMs + 500) / 1000).toInt()
        return when {
            seconds < 60 -> context.getString(R.string.duration_seconds, seconds)
            seconds < 3600 -> context.getString(R.string.duration_minutes_seconds, seconds / 60, seconds % 60)
            else -> context.getString(R.string.duration_hours_minutes, seconds / 3600, seconds % 3600 / 60)
        }
    }

    /** The time left alone, for a big number: "25 s", "1 min 15 s", "2 h 5 min". Null while unknown. */
    fun timeLeftShort(context: Context, progress: TransferProgress): String? {
        val rounded = secondsLeft(progress) ?: return null
        return when {
            rounded < 60 -> context.getString(R.string.duration_seconds, rounded)
            rounded < 3600 && rounded % 60 != 0 -> context.getString(R.string.duration_minutes_seconds, rounded / 60, rounded % 60)
            rounded < 3600 -> context.getString(R.string.chip_minutes, rounded / 60)
            else -> context.getString(R.string.duration_hours_minutes, rounded / 3600, rounded % 3600 / 60)
        }
    }

    /**
     * Roughly how long the transfer still takes, from its recent speed, rounded up so the number
     * doesn't jitter: whole seconds up to 10, steps of 5 seconds up to a minute, then minutes and
     * seconds in steps of 15 (so it moves about every 15 seconds), from an hour hours and minutes.
     * Null while unknown.
     */
    fun timeLeft(context: Context, progress: TransferProgress): String? {
        val rounded = secondsLeft(progress) ?: return null
        return when {
            rounded < 60 -> context.getString(R.string.transfer_seconds_left, rounded)
            rounded < 3600 && rounded % 60 != 0 -> context.getString(R.string.transfer_minutes_seconds_left, rounded / 60, rounded % 60)
            rounded < 3600 -> context.getString(R.string.transfer_minutes_left, rounded / 60)
            else -> context.getString(R.string.transfer_hours_minutes_left, rounded / 3600, rounded % 3600 / 60)
        }
    }

    private fun secondsLeft(progress: TransferProgress): Int? {
        val remaining = progress.totalBytes - progress.bytesSent
        if (progress.averageBytesPerSecond <= 0 || remaining <= 0) return null
        val seconds = remaining.toDouble() / progress.averageBytesPerSecond
        val step = when {
            seconds < 10 -> 1
            seconds < 60 -> 5
            seconds < 3600 -> 15
            else -> 60
        }
        return maxOf(1, (ceil(seconds / step) * step).toInt())
    }
}

/** The text as a web link when it is one and nothing else, so it can be opened: null otherwise. */
fun webLink(text: String): Uri? = text.trim()
    .takeIf { it.isNotEmpty() && !it.contains(Regex("\\s")) }
    ?.let(Uri::parse)
    ?.takeIf { it.scheme == "http" || it.scheme == "https" }
