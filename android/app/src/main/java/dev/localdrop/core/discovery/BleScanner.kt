package dev.localdrop.core.discovery

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import dev.localdrop.core.presence.PresenceCrypto
import dev.localdrop.core.protocol.ProtocolConstants
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** What a LocalDrop advertisement says about its sender (protocol.md §2.2). */
sealed interface AdvertisedIdentity {
    /** Private mode: recognizable only with the sender's presence key; [status] is its state. */
    class PrivateToken(val token: ByteArray, val status: AdvertisedStatus) : AdvertisedIdentity

    /** Pairing mode: discoverable by anyone nearby. */
    data class Pairing(val shortId: String) : AdvertisedIdentity

    /** The name wasn't in the advertisement (or is malformed). */
    data object Unknown : AdvertisedIdentity
}

/** First letter of a private-mode name (protocol.md §2.2). */
enum class AdvertisedStatus(val letter: Char) {
    Available('L'),
    NoNetwork('N'),
    Busy('B'),
}

/** One LocalDrop advertisement as seen by the scanner. */
data class Advertisement(
    val device: BluetoothDevice,
    val identity: AdvertisedIdentity,
    val rssi: Int,
    val seenAtElapsedMs: Long,
) {
    /** Pairing-mode short id, or null. */
    val shortId: String? get() = (identity as? AdvertisedIdentity.Pairing)?.shortId
}

class ScanFailedException(val errorCode: Int) : Exception("BLE scan failed: ${describe(errorCode)}") {
    companion object {
        fun describe(code: Int): String = when (code) {
            ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "already started"
            ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "app registration failed"
            ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "internal error"
            ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "feature unsupported"
            ScanCallback.SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES -> "out of hardware resources"
            ScanCallback.SCAN_FAILED_SCANNING_TOO_FREQUENTLY -> "scanning too frequently"
            else -> "error $code"
        }
    }
}

/**
 * Scans for the LocalDrop service UUID. The flow runs the scan while collected.
 *
 * Android silently blocks apps that start scans more than 5 times per 30 s, so consecutive
 * starts are spaced at least [MIN_START_INTERVAL_MS] apart.
 */
class BleScanner(private val environment: BluetoothEnvironment) {

    private val startLock = Mutex()
    private var lastStartElapsedMs = Long.MIN_VALUE / 2

    // Permissions are verified by BluetoothEnvironment before scanning starts; a revoked
    // permission surfaces as SecurityException and is handled by the caller.
    @SuppressLint("MissingPermission")
    /**
     * @param background for long watching while something waits: balanced mode notices a Mac
     *   within seconds at a fraction of low-latency cost. (Low-power mode missed a Mac that
     *   woke up for 20+ s on a Mi A2 with the screen off.)
     */
    fun scan(background: Boolean = false): Flow<Advertisement> = callbackFlow {
        val scanner = environment.adapter?.bluetoothLeScanner
            ?: throw IllegalStateException("Bluetooth LE scanner unavailable (Bluetooth off?)")

        startLock.withLock {
            val wait = lastStartElapsedMs + MIN_START_INTERVAL_MS - SystemClock.elapsedRealtime()
            if (wait > 0) delay(wait)
            lastStartElapsedMs = SystemClock.elapsedRealtime()
        }

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                trySend(result.toAdvertisement())
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { trySend(it.toAdvertisement()) }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.e(TAG, "Scan failed: ${ScanFailedException.describe(errorCode)}")
                close(ScanFailedException(errorCode))
            }
        }

        // A Mac with files for a phone advertises a pending-delivery UUID instead (protocol.md §2.8).
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(ProtocolConstants.SERVICE_UUID)).build(),
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid(ProtocolConstants.PENDING_DELIVERY_PREFIX), ParcelUuid(ProtocolConstants.PENDING_DELIVERY_MASK))
                .build(),
        )
        val settings = ScanSettings.Builder()
            .setScanMode(if (background) ScanSettings.SCAN_MODE_BALANCED else ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setReportDelay(0)
            .build()

        Log.i(TAG, if (background) "Starting background BLE scan" else "Starting BLE scan")
        scanner.startScan(filters, settings, callback)

        awaitClose {
            Log.i(TAG, "Stopping BLE scan")
            try {
                scanner.stopScan(callback)
            } catch (e: IllegalStateException) {
                // Thrown when Bluetooth was turned off while scanning; the scan is already gone.
                Log.w(TAG, "stopScan after Bluetooth turned off: ${e.message}")
            } catch (e: SecurityException) {
                Log.w(TAG, "stopScan without permission: ${e.message}")
            }
        }
    }

    private fun ScanResult.toAdvertisement(): Advertisement = Advertisement(
        device = device,
        identity = parseIdentity(scanRecord?.deviceName),
        rssi = rssi,
        seenAtElapsedMs = SystemClock.elapsedRealtime(),
    )

    companion object {
        private const val TAG = "LD/discovery"
        private const val MIN_START_INTERVAL_MS = 6_000L
        private val PAIRING_PATTERN = Regex(
            "^${ProtocolConstants.PAIRING_NAME_PREFIX}([0-9a-f]{${ProtocolConstants.SHORT_ID_LENGTH}})$",
        )
        private val PRIVATE_PATTERN = Regex("^([LNB])([A-Za-z0-9_-]{7})$")

        fun parseIdentity(localName: String?): AdvertisedIdentity {
            if (localName == null) return AdvertisedIdentity.Unknown
            PAIRING_PATTERN.matchEntire(localName)?.let { return AdvertisedIdentity.Pairing(it.groupValues[1]) }
            PRIVATE_PATTERN.matchEntire(localName)?.let { match ->
                val status = AdvertisedStatus.entries.first { it.letter == match.groupValues[1][0] }
                PresenceCrypto.decodeToken(match.groupValues[2])?.let { return AdvertisedIdentity.PrivateToken(it, status) }
            }
            return AdvertisedIdentity.Unknown
        }
    }
}
