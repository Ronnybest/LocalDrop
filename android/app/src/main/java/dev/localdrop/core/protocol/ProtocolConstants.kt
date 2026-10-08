package dev.localdrop.core.protocol

import java.util.UUID

/** Values fixed by protocol/protocol.md. Changing any of them is a protocol change. */
object ProtocolConstants {
    const val VERSION = 1L
    const val MIN_SUPPORTED_VERSION = 1L

    val SERVICE_UUID: UUID = UUID.fromString("8D232B6B-5901-4AEA-89A2-389415C619EB")
    val ENDPOINT_INFO_CHARACTERISTIC_UUID: UUID = UUID.fromString("13391BAF-1674-4EF2-A1E1-AAD175FE6C3F")

    /**
     * While a Mac has files for a phone it advertises, instead of [SERVICE_UUID], a UUID made of
     * these 8 bytes and the phone's 8-byte delivery tag (protocol.md §2.8). Scan filters match the
     * prefix with [PENDING_DELIVERY_MASK].
     */
    val PENDING_DELIVERY_PREFIX: UUID = UUID(0x137D2908412B445FL, 0L)
    val PENDING_DELIVERY_MASK: UUID = UUID(-1L, 0L)

    /** The delivery tag in a pending-delivery UUID, or null for any other UUID. */
    fun pendingDeliveryTag(uuid: UUID): ByteArray? {
        if (uuid.mostSignificantBits != PENDING_DELIVERY_PREFIX.mostSignificantBits) return null
        val bits = uuid.leastSignificantBits
        return ByteArray(8) { i -> (bits ushr (8 * (7 - i))).toByte() }
    }

    /** BLE local name prefix in pairing mode (protocol.md §2.2); private names start with a status letter. */
    const val PAIRING_NAME_PREFIX = "P"
    const val SHORT_ID_LENGTH = 6

    /** What this phone can do (protocol.md §2.6). */
    val CAPABILITIES = listOf("files", "multipleFiles", "text", "receive")

    /** The Mac can send to this phone (protocol.md §2.6). */
    const val CAP_SEND = "send"

    /** The peer takes a `text` message straight to its clipboard (protocol.md §2.6). */
    const val CAP_CLIPBOARD_RECEIVE = "clipboardReceive"

    /** Longest `text` message in UTF-8 bytes; longer text goes as a .txt file (protocol/messages.md). */
    const val MAX_TEXT_SIZE = 262_144

    const val BONJOUR_SERVICE_TYPE = "_localdrop._tcp"

    const val MAX_FRAME_SIZE = 1_048_576 + 64
    const val MAX_CHUNK_SIZE = 1_048_576

    /** Sender-side chunk size. Not part of the wire contract; receivers accept up to [MAX_CHUNK_SIZE]. */
    const val CHUNK_SIZE = 256 * 1024

    /** A Mac advertises every second or so; this long without one means it left, slept or turned Bluetooth off. */
    const val DEVICE_STALE_TIMEOUT_MS = 8_000L

    const val PLATFORM = "android"
}
