package dev.localdrop.core.protocol

/** Value of the Endpoint Info GATT characteristic (protocol/protocol.md §2.3). */
data class EndpointInfo(
    val protocolVersion: Long,
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val port: Int,
    val addresses: List<String>,
    val fingerprint: ByteArray,
    val busy: Boolean = false,
    val capabilities: List<String> = emptyList(),
) {
    /** Lowercase hex of the deviceId without dashes; the advertised shortId is its prefix. */
    val compactDeviceId: String get() = deviceId.replace("-", "").lowercase()

    override fun equals(other: Any?): Boolean =
        other is EndpointInfo &&
            protocolVersion == other.protocolVersion &&
            deviceId == other.deviceId &&
            deviceName == other.deviceName &&
            platform == other.platform &&
            port == other.port &&
            addresses == other.addresses &&
            fingerprint.contentEquals(other.fingerprint)

    override fun hashCode(): Int =
        listOf(protocolVersion, deviceId, deviceName, platform, port, addresses, fingerprint.contentHashCode()).hashCode()

    companion object {
        private const val FINGERPRINT_SIZE = 32

        /**
         * Decodes the characteristic value: open (pairing mode) or sealed with a presence key
         * (private mode, protocol.md §2.3). [openSealed] turns the sealed bytes into the open form.
         * @throws CborException if the payload is malformed, sealed without a way to open it, or invalid.
         */
        fun decode(bytes: ByteArray, openSealed: ((ByteArray) -> ByteArray)? = null): EndpointInfo {
            val outer = Cbor.decode(bytes) as? CborValue.Map ?: throw CborException("endpoint info is not a map")
            val sealed = (outer.entries["sealed"] as? CborValue.Bytes)?.value
            val map = if (sealed == null) {
                outer
            } else {
                val open = openSealed ?: throw CborException("endpoint info is sealed")
                Cbor.decode(open(sealed)) as? CborValue.Map ?: throw CborException("sealed endpoint info is not a map")
            }
            val port = map.uint("port")
            if (port !in 1..65_535) throw CborException("port out of range: $port")
            val fingerprint = map.bytes("fp")
            if (fingerprint.size != FINGERPRINT_SIZE) throw CborException("fingerprint must be $FINGERPRINT_SIZE bytes")
            val addresses = map.array("addrs").map {
                (it as? CborValue.Text)?.value ?: throw CborException("address is not a text string")
            }
            return EndpointInfo(
                protocolVersion = map.uint("v"),
                deviceId = map.text("id"),
                deviceName = map.text("name"),
                platform = map.text("platform"),
                port = port.toInt(),
                addresses = addresses,
                fingerprint = fingerprint,
                busy = (map.entries["busy"] as? CborValue.Bool)?.value ?: false,
                capabilities = (map.entries["caps"] as? CborValue.Array)?.items?.mapNotNull { (it as? CborValue.Text)?.value }.orEmpty(),
            )
        }
    }
}
