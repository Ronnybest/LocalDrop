package dev.localdrop.core.transport

import dev.localdrop.core.discovery.DiscoveryBlocker
import dev.localdrop.core.protocol.ErrorCode

/** Every way connecting to or talking with a peer can fail. Each case has its own UI message. */
sealed class ConnectionException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** No Wi-Fi or Ethernet network: LocalDrop never sends over mobile data. */
    class NoLocalNetwork : ConnectionException("No Wi-Fi or Ethernet network")

    class Refused(cause: Throwable) : ConnectionException("Connection refused", cause)

    /**
     * A VPN on this phone keeps the connection off the local network: an always-on VPN that blocks
     * other connections forbids binding to the Wi-Fi, and a VPN without local network access
     * sends LAN traffic into its tunnel.
     */
    class BlockedByVpn(cause: Throwable?) : ConnectionException("A VPN blocks the local network", cause)

    /** No address answered in time or a route was missing — typically different networks or client isolation. */
    class Unreachable(cause: Throwable?) : ConnectionException("Peer unreachable", cause)

    class Timeout(val stage: String) : ConnectionException("Timed out waiting for $stage")

    class ConnectionLost(cause: Throwable?) : ConnectionException("Connection lost", cause)

    class IncompatibleVersion(val peerSupported: List<Long>?) :
        ConnectionException("Incompatible protocol version (peer supports $peerSupported)")

    /** The peer could not prove the identity it claims, or is a different device than expected. */
    class AuthenticationFailed(reason: String) : ConnectionException("Authentication failed: $reason")

    class DecryptionFailed : ConnectionException("Decryption failed")

    class ProtocolViolation(detail: String) : ConnectionException("Protocol violation: $detail")

    /** The peer reported an error and closed the session. */
    class PeerError(val code: String, detail: String?) : ConnectionException("Peer error $code: ${detail ?: "-"}")

    /** Pairing was declined; [byPeer] is true when the other device's user declined. */
    class PairingRejected(val byPeer: Boolean) : ConnectionException("Pairing declined")

    /** The peer ended the session normally (`close`). */
    class ClosedByPeer : ConnectionException("Closed by peer")

    /** A file received from the Mac couldn't be saved on this phone (storage full, write error). */
    class SaveFailed(val fileName: String, cause: Throwable?) : ConnectionException("Could not save $fileName", cause)

    /** Not enough free space on this phone for what the Mac wants to send. */
    class NotEnoughSpace(val needed: Long) : ConnectionException("Not enough space for $needed bytes")

    /** The trusted-devices store could not be written. */
    class StorageFailed(cause: Throwable) : ConnectionException("Could not save trusted device", cause)

    /** The receiver declined the transfer request; [reason] is a `transfer_reject.reason`. */
    class TransferRejected(val reason: String) : ConnectionException("Transfer rejected: $reason")

    /** The receiver reported a failure (`file_result`/`transfer_result`); [code] is an error code. */
    class ReceiverFailed(val code: String, val fileName: String?) :
        ConnectionException("Receiver failed: $code (${fileName ?: "-"})")

    /** A file being sent can no longer be read (deleted, permission revoked, shorter than announced). */
    class SourceUnavailable(val fileName: String, cause: Throwable?) :
        ConnectionException("Cannot read $fileName", cause)

    /** Bluetooth can't be used to find the device; [blocker] says why, when known. */
    class BluetoothUnavailable(val blocker: DiscoveryBlocker?, cause: Throwable? = null) :
        ConnectionException("Bluetooth unavailable: $blocker", cause)

    /** The target device wasn't found nearby (asleep, out of range, LocalDrop not running). */
    class NotNearby : ConnectionException("Device not nearby")

    /** The device's BLE token was seen, but it never answered over Bluetooth or the network. */
    class NearbyButUnresponsive : ConnectionException("Device nearby but unresponsive")

    /** The receiver cancelled the transfer. */
    class CancelledByPeer : ConnectionException("Cancelled by peer")

    /** The local identity key can't be used (Keystore failure). */
    class IdentityUnavailable(cause: Throwable) : ConnectionException("Identity key unavailable", cause)

    /**
     * The device just wasn't available — asleep, away, on another network, busy, or the
     * connection dropped — so the same send may work later. Everything else (declined, untrusted,
     * unreadable source, incompatible) would fail again the same way.
     */
    val isTemporary: Boolean
        get() = when (this) {
            is NoLocalNetwork, is Refused, is Unreachable, is Timeout, is ConnectionLost, is ClosedByPeer,
            is BluetoothUnavailable, is NotNearby, is NearbyButUnresponsive,
            -> true
            is PeerError -> code == ErrorCode.BUSY
            is TransferRejected -> reason == "busy" || reason == "asleep"
            else -> false
        }

    /** Code to send to the peer before closing, or null when the peer can't or needn't be told. */
    val wireCode: String?
        get() = when (this) {
            is ProtocolViolation -> ErrorCode.BAD_MESSAGE
            is AuthenticationFailed -> ErrorCode.AUTH_FAILED
            is DecryptionFailed -> ErrorCode.DECRYPT_FAILED
            is IncompatibleVersion -> ErrorCode.VERSION_UNSUPPORTED
            is StorageFailed -> ErrorCode.INTERNAL
            else -> null
        }
}
