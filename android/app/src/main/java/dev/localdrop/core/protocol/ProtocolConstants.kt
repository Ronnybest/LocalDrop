package dev.localdrop.core.protocol

import java.util.UUID

/** Values fixed by protocol/protocol.md. Changing any of them is a protocol change. */
object ProtocolConstants {
    const val VERSION = 1L
    const val MIN_SUPPORTED_VERSION = 1L

    val SERVICE_UUID: UUID = UUID.fromString("8D232B6B-5901-4AEA-89A2-389415C619EB")
    val ENDPOINT_INFO_CHARACTERISTIC_UUID: UUID = UUID.fromString("13391BAF-1674-4EF2-A1E1-AAD175FE6C3F")

    /** BLE local name prefix in pairing mode (protocol.md §2.2); private names start with a status letter. */
    const val PAIRING_NAME_PREFIX = "P"
    const val SHORT_ID_LENGTH = 6

    /** What this phone can do (protocol.md §2.6). */
    val CAPABILITIES = listOf("files", "multipleFiles", "text")

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
