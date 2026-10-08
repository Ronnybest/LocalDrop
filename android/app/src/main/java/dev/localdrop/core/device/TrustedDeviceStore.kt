package dev.localdrop.core.device

import android.util.Log
import androidx.core.util.AtomicFile
import dev.localdrop.core.protocol.Cbor
import dev.localdrop.core.protocol.CborException
import dev.localdrop.core.protocol.CborValue
import dev.localdrop.core.protocol.bytes
import dev.localdrop.core.protocol.text
import dev.localdrop.core.protocol.uint
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A device paired by the user (protocol/security.md §6). */
class TrustedDevice(
    val deviceId: String,
    val deviceName: String,
    /** Identity public key, X9.63. */
    val publicKey: ByteArray,
    val fingerprint: ByteArray,
    val firstSeenMs: Long,
    val lastSeenMs: Long,
    /** Where the device answered last time; tried first, before any Bluetooth discovery. */
    val lastAddresses: List<String> = emptyList(),
    val lastPort: Int? = null,
    /** The Mac's presence key: recognizes its private BLE token and opens its Endpoint Info. */
    val presenceKey: ByteArray? = null,
    val capabilities: List<String> = emptyList(),
    /** Chosen by the user; see [defaultDevice]. */
    val isDefault: Boolean = false,
) {
    fun copy(
        deviceName: String = this.deviceName,
        lastSeenMs: Long = this.lastSeenMs,
        lastAddresses: List<String> = this.lastAddresses,
        lastPort: Int? = this.lastPort,
        presenceKey: ByteArray? = this.presenceKey,
        capabilities: List<String> = this.capabilities,
        isDefault: Boolean = this.isDefault,
    ) = TrustedDevice(
        deviceId, deviceName, publicKey, fingerprint, firstSeenMs, lastSeenMs, lastAddresses, lastPort, presenceKey, capabilities, isDefault,
    )
}

/**
 * Where a send without an explicit target goes (the plain LocalDrop share target, the
 * clipboard tile): the Mac the user made default, or the only one.
 */
fun List<TrustedDevice>.defaultDevice(): TrustedDevice? = firstOrNull { it.isDefault } ?: singleOrNull()

enum class TrustState {
    Unknown,
    Trusted,

    /** The deviceId is known with a different key. Never trusted silently. */
    KeyChanged,
}

/**
 * Trusted devices persisted as CBOR in `noBackupFilesDir`, so they never leave this phone via
 * backup or device transfer. Writes are atomic. Public keys are not secret; this phone's private
 * key stays in Android Keystore.
 */
class TrustedDeviceStore(private val file: File, private val clock: () -> Long = System::currentTimeMillis) {

    private val atomicFile = AtomicFile(file)
    private val _devices = MutableStateFlow<List<TrustedDevice>>(emptyList())
    val devices: StateFlow<List<TrustedDevice>> = _devices.asStateFlow()
    private var loaded = false

    /** Reads the file once. An unreadable file is moved aside: the user re-pairs, nobody is trusted by accident. */
    @Synchronized
    fun load() {
        if (loaded) return
        loaded = true
        _devices.value = try {
            decode(atomicFile.readFully()).also { Log.i(TAG, "Loaded ${it.size} trusted device(s)") }
        } catch (e: FileNotFoundException) {
            emptyList()
        } catch (e: IOException) {
            Log.e(TAG, "Trusted devices unreadable, starting empty", e)
            emptyList()
        } catch (e: CborException) {
            val aside = File(file.parentFile, "${file.name}.corrupt-${clock()}")
            Log.e(TAG, "Trusted devices file corrupt (${e.message}); moved to ${aside.name}")
            file.renameTo(aside)
            emptyList()
        }
    }

    @Synchronized
    fun find(deviceId: String): TrustedDevice? {
        load()
        return _devices.value.firstOrNull { it.deviceId == deviceId }
    }

    @Synchronized
    fun trustState(deviceId: String, publicKey: ByteArray): TrustState {
        load()
        val device = _devices.value.firstOrNull { it.deviceId == deviceId } ?: return TrustState.Unknown
        return if (device.publicKey.contentEquals(publicKey)) TrustState.Trusted else TrustState.KeyChanged
    }

    /** Adds the device, replacing any previous key for the same deviceId (after re-pairing). */
    @Synchronized
    @Throws(IOException::class)
    fun trust(
        deviceId: String,
        deviceName: String,
        publicKey: ByteArray,
        fingerprint: ByteArray,
        presenceKey: ByteArray? = null,
        capabilities: List<String> = emptyList(),
    ) {
        load()
        val now = clock()
        val previous = _devices.value.firstOrNull { it.deviceId == deviceId && it.publicKey.contentEquals(publicKey) }
        val updated = _devices.value.filter { it.deviceId != deviceId } +
            TrustedDevice(
                deviceId, deviceName, publicKey, fingerprint, previous?.firstSeenMs ?: now, now,
                previous?.lastAddresses.orEmpty(), previous?.lastPort, presenceKey ?: previous?.presenceKey, capabilities,
                previous?.isDefault ?: false,
            )
        write(updated)
        Log.i(TAG, "Trusted $deviceId")
    }

    @Synchronized
    fun markSeen(deviceId: String, deviceName: String) {
        load()
        val updated = _devices.value.map { if (it.deviceId == deviceId) it.copy(deviceName = deviceName, lastSeenMs = clock()) else it }
        try {
            write(updated)
        } catch (e: IOException) {
            Log.w(TAG, "Could not update lastSeen for $deviceId", e)
        }
    }

    /** Remembers the endpoint of an authenticated session for the next connection. */
    @Synchronized
    fun rememberEndpoint(deviceId: String, addresses: List<String>, port: Int) {
        load()
        val current = _devices.value.firstOrNull { it.deviceId == deviceId } ?: return
        if (current.lastAddresses == addresses && current.lastPort == port) return
        update(deviceId) { it.copy(lastAddresses = addresses, lastPort = port) }
    }

    /** Stores what an authenticated session revealed: presence key (it rotates) and capabilities. */
    @Synchronized
    fun rememberSessionInfo(deviceId: String, presenceKey: ByteArray?, capabilities: List<String>) {
        load()
        val current = _devices.value.firstOrNull { it.deviceId == deviceId } ?: return
        val key = presenceKey ?: current.presenceKey
        if (current.presenceKey.contentEqualsNullable(key) && current.capabilities == capabilities) return
        update(deviceId) { it.copy(presenceKey = key, capabilities = capabilities) }
    }

    /** Makes [deviceId] the default Mac; every other device stops being default. */
    @Synchronized
    @Throws(IOException::class)
    fun setDefault(deviceId: String) {
        load()
        if (_devices.value.none { it.deviceId == deviceId }) return
        write(_devices.value.map { it.copy(isDefault = it.deviceId == deviceId) })
        Log.i(TAG, "Default device: $deviceId")
    }

    private fun update(deviceId: String, transform: (TrustedDevice) -> TrustedDevice) {
        val updated = _devices.value.map { if (it.deviceId == deviceId) transform(it) else it }
        try {
            write(updated)
        } catch (e: IOException) {
            Log.w(TAG, "Could not update $deviceId", e)
        }
    }

    private fun ByteArray?.contentEqualsNullable(other: ByteArray?): Boolean =
        if (this == null || other == null) this === other else contentEquals(other)

    @Synchronized
    @Throws(IOException::class)
    fun forget(deviceId: String) {
        load()
        write(_devices.value.filter { it.deviceId != deviceId })
        Log.i(TAG, "Forgot $deviceId")
    }

    private fun write(devices: List<TrustedDevice>) {
        val stream = atomicFile.startWrite()
        try {
            stream.write(encode(devices))
            atomicFile.finishWrite(stream)
        } catch (e: IOException) {
            atomicFile.failWrite(stream)
            throw e
        }
        _devices.value = devices
    }

    private companion object {
        const val TAG = "LD/trust"
        const val FORMAT_VERSION = 1L

        fun encode(devices: List<TrustedDevice>): ByteArray = Cbor.encode(
            CborValue.Map(
                mapOf(
                    "version" to CborValue.UInt(FORMAT_VERSION),
                    "devices" to CborValue.Array(
                        devices.map {
                            CborValue.Map(
                                mapOf(
                                    "deviceId" to CborValue.Text(it.deviceId),
                                    "deviceName" to CborValue.Text(it.deviceName),
                                    "publicKey" to CborValue.Bytes(it.publicKey),
                                    "fingerprint" to CborValue.Bytes(it.fingerprint),
                                    "firstSeen" to CborValue.UInt(it.firstSeenMs),
                                    "lastSeen" to CborValue.UInt(it.lastSeenMs),
                                    "lastAddrs" to CborValue.Array(it.lastAddresses.map(CborValue::Text)),
                                    "caps" to CborValue.Array(it.capabilities.map(CborValue::Text)),
                                ) + listOfNotNull(
                                    it.lastPort?.let { port -> "lastPort" to CborValue.UInt(port.toLong()) },
                                    it.presenceKey?.let { key -> "presenceKey" to CborValue.Bytes(key) },
                                    if (it.isDefault) "default" to CborValue.Bool(true) else null,
                                ).toMap(),
                            )
                        },
                    ),
                ),
            ),
        )

        fun decode(bytes: ByteArray): List<TrustedDevice> {
            val root = Cbor.decode(bytes) as? CborValue.Map ?: throw CborException("root is not a map")
            if (root.uint("version") != FORMAT_VERSION) throw CborException("unsupported store version")
            val list = root.entries["devices"] as? CborValue.Array ?: throw CborException("missing devices")
            return list.items.map { item ->
                val map = item as? CborValue.Map ?: throw CborException("device is not a map")
                TrustedDevice(
                    deviceId = map.text("deviceId"),
                    deviceName = map.text("deviceName"),
                    publicKey = map.bytes("publicKey"),
                    fingerprint = map.bytes("fingerprint"),
                    firstSeenMs = map.uint("firstSeen"),
                    lastSeenMs = map.uint("lastSeen"),
                    // Optional: absent in records written before endpoints were remembered.
                    lastAddresses = (map.entries["lastAddrs"] as? CborValue.Array)?.items
                        ?.mapNotNull { (it as? CborValue.Text)?.value }.orEmpty(),
                    lastPort = (map.entries["lastPort"] as? CborValue.UInt)?.value?.toInt(),
                    presenceKey = (map.entries["presenceKey"] as? CborValue.Bytes)?.value,
                    capabilities = (map.entries["caps"] as? CborValue.Array)?.items
                        ?.mapNotNull { (it as? CborValue.Text)?.value }.orEmpty(),
                    isDefault = (map.entries["default"] as? CborValue.Bool)?.value ?: false,
                )
            }
        }
    }
}
