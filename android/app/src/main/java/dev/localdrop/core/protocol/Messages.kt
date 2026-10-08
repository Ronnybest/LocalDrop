package dev.localdrop.core.protocol

/** Message type identifiers (`t` field), protocol/messages.md. */
object MessageType {
    const val CLIENT_HELLO = "client_hello"
    const val SERVER_HELLO = "server_hello"
    const val CLIENT_NONCE = "client_nonce"
    const val SERVER_AUTH = "server_auth"
    const val CLIENT_AUTH = "client_auth"
    const val SESSION_STATUS = "session_status"
    const val PAIRING_CONFIRM = "pairing_confirm"
    const val PAIRING_RESULT = "pairing_result"
    const val TRANSFER_REQUEST = "transfer_request"
    const val TRANSFER_ACCEPT = "transfer_accept"
    const val TRANSFER_REJECT = "transfer_reject"
    const val FILE_BEGIN = "file_begin"
    const val FILE_CHUNK = "file_chunk"
    const val FILE_END = "file_end"
    const val FILE_RESULT = "file_result"
    const val TRANSFER_COMPLETE = "transfer_complete"
    const val TRANSFER_RESULT = "transfer_result"
    const val CANCEL = "cancel"
    const val TRANSFER_ADD = "transfer_add"
    const val TEXT = "text"
    const val TEXT_RESULT = "text_result"
    const val CLOSE = "close"
    const val ERROR = "error"
}

/** Error codes of the `error` message, protocol/messages.md. */
object ErrorCode {
    const val VERSION_UNSUPPORTED = "version_unsupported"
    const val BAD_MESSAGE = "bad_message"
    const val AUTH_FAILED = "auth_failed"
    const val DECRYPT_FAILED = "decrypt_failed"
    const val PAIRING_REJECTED = "pairing_rejected"
    const val PAIRING_TIMEOUT = "pairing_timeout"
    const val NOT_TRUSTED = "not_trusted"
    const val BUSY = "busy"
    const val PAIRING_UNAVAILABLE = "pairing_unavailable"
    const val INSUFFICIENT_STORAGE = "insufficient_storage"
    const val WRITE_FAILED = "write_failed"
    const val CHECKSUM_MISMATCH = "checksum_mismatch"
    const val SOURCE_UNAVAILABLE = "source_unavailable"
    const val INTERNAL = "internal"
}

/** A decoded protocol message: its type plus the remaining fields. */
class Message(val type: String, val body: Map<String, CborValue> = emptyMap()) {

    fun toCbor(): CborValue.Map = CborValue.Map(body + ("t" to CborValue.Text(type)))

    fun encode(): ByteArray = Cbor.encode(toCbor())

    fun expect(expected: String): Message {
        if (type != expected) throw CborException("expected $expected, got $type")
        return this
    }

    private val map get() = CborValue.Map(body)
    fun text(key: String): String = map.text(key)
    fun bool(key: String): Boolean = map.bool(key)
    fun uint(key: String): Long = map.uint(key)

    fun bytes(key: String, size: Int? = null): ByteArray = map.bytes(key).also {
        if (size != null && it.size != size) throw CborException("$type: '$key' must be $size bytes")
    }

    companion object {
        /** @throws CborException for malformed payloads or a missing type. */
        fun decode(payload: ByteArray): Message {
            val map = Cbor.decode(payload) as? CborValue.Map ?: throw CborException("message is not a map")
            val type = (map.entries["t"] as? CborValue.Text)?.value ?: throw CborException("message has no type")
            return Message(type, map.entries - "t")
        }
    }
}

data class ClientHello(
    val version: Long,
    val minVersion: Long,
    val deviceId: String,
    val name: String,
    val platform: String,
    val identityKey: ByteArray,
    val ephemeralKey: ByteArray,
    val nonceCommit: ByteArray,
    val capabilities: List<String>,
) {
    fun toMessage() = Message(
        MessageType.CLIENT_HELLO,
        mapOf(
            "caps" to CborValue.Array(capabilities.map(CborValue::Text)),
            "v" to CborValue.UInt(version),
            "minV" to CborValue.UInt(minVersion),
            "id" to CborValue.Text(deviceId),
            "name" to CborValue.Text(name),
            "platform" to CborValue.Text(platform),
            "idKey" to CborValue.Bytes(identityKey),
            "eph" to CborValue.Bytes(ephemeralKey),
            "nonceCommit" to CborValue.Bytes(nonceCommit),
        ),
    )
}

class ServerHello(
    val version: Long,
    val deviceId: String,
    val name: String,
    val platform: String,
    val identityKey: ByteArray,
    val ephemeralKey: ByteArray,
    val nonce: ByteArray,
    val capabilities: List<String>,
) {
    companion object {
        fun from(message: Message): ServerHello {
            message.expect(MessageType.SERVER_HELLO)
            return ServerHello(
                version = message.uint("v"),
                deviceId = message.text("id"),
                name = message.text("name"),
                platform = message.text("platform"),
                identityKey = message.bytes("idKey", 65),
                ephemeralKey = message.bytes("eph", 65),
                nonce = message.bytes("nonce", 32),
                capabilities = (message.body["caps"] as? CborValue.Array)?.items?.mapNotNull { (it as? CborValue.Text)?.value }.orEmpty(),
            )
        }
    }
}

enum class SessionStatus(val wire: String) {
    Trusted("trusted"),
    PairingRequired("pairing_required"),
    KeyChanged("key_changed"),
    ;

    companion object {
        fun from(message: Message): SessionStatus {
            message.expect(MessageType.SESSION_STATUS)
            val value = message.text("status")
            return entries.firstOrNull { it.wire == value } ?: throw CborException("unknown session status '$value'")
        }
    }
}

/** Optional 32-byte presence key in `session_status` / `pairing_result` (messages.md). */
fun Message.presenceKey(): ByteArray? = (body["presenceKey"] as? CborValue.Bytes)?.value?.takeIf { it.size == 32 }

class ErrorMessage(val code: String, val detail: String?, val supported: List<Long>?) {
    companion object {
        fun from(message: Message): ErrorMessage {
            message.expect(MessageType.ERROR)
            return ErrorMessage(
                code = message.text("code"),
                detail = (message.body["message"] as? CborValue.Text)?.value,
                supported = (message.body["supported"] as? CborValue.Array)?.items?.mapNotNull { (it as? CborValue.UInt)?.value },
            )
        }

        fun create(code: String, detail: String? = null) = Message(
            MessageType.ERROR,
            buildMap {
                put("code", CborValue.Text(code))
                if (detail != null) put("message", CborValue.Text(detail))
            },
        )
    }
}
