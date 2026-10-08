package dev.localdrop.core.discovery

import android.util.Log
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.presence.PresenceCrypto
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.core.transport.ConnectionException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout

/**
 * Finds one specific trusted device nearby over BLE and reads its current endpoint. The device is
 * recognized by its private presence token (or its short id while it is in pairing mode).
 */
class DeviceResolver(
    private val environment: BluetoothEnvironment,
    private val scanner: BleScanner,
    private val gattReader: GattEndpointReader,
) {
    /** @throws ConnectionException.BluetoothUnavailable, NotNearby, NearbyButUnresponsive */
    suspend fun resolve(device: TrustedDevice, timeoutMs: Long = RESOLVE_TIMEOUT_MS): EndpointInfo {
        environment.currentBlocker()?.let { throw ConnectionException.BluetoothUnavailable(it) }
        val compactId = device.deviceId.replace("-", "").lowercase()
        Log.i(TAG, "Looking for ${device.deviceId} nearby")
        var seen = false
        return try {
            withTimeout(timeoutMs) {
                scanUntilFound(device, compactId) { seen = true }
            }
        } catch (e: TimeoutCancellationException) {
            // Seen but never answered over GATT is a different problem than not being around.
            throw if (seen) ConnectionException.NearbyButUnresponsive() else ConnectionException.NotNearby()
        } catch (e: ScanFailedException) {
            throw ConnectionException.BluetoothUnavailable(null, e)
        } catch (e: SecurityException) {
            throw ConnectionException.BluetoothUnavailable(environment.currentBlocker(), e)
        }
    }

    private suspend fun scanUntilFound(device: TrustedDevice, compactId: String, onSeen: () -> Unit): EndpointInfo {
        while (true) {
            val advertisement = scanner.scan().filter { isFrom(device, compactId, it.identity) }.first()
            onSeen()
            val info = try {
                gattReader.read(advertisement.device, device.presenceKey)
            } catch (e: GattReadException) {
                Log.w(TAG, "Endpoint read failed, scanning again: ${e.message}")
                continue
            }
            // A token or short id is only a hint; the full id must match (and the handshake proves it).
            if (info.compactDeviceId == compactId) {
                Log.i(TAG, "Resolved ${device.deviceId} over BLE: port ${info.port}, ${info.addresses.size} address(es)")
                return info
            }
            Log.w(TAG, "Advertisement matched ${device.deviceId} but endpoint is ${info.deviceId}; ignoring")
        }
    }

    private fun isFrom(device: TrustedDevice, compactId: String, identity: AdvertisedIdentity): Boolean = when (identity) {
        is AdvertisedIdentity.PrivateToken -> device.presenceKey?.let {
            PresenceCrypto.matches(identity.token, it, System.currentTimeMillis())
        } ?: false
        is AdvertisedIdentity.Pairing -> compactId.startsWith(identity.shortId)
        AdvertisedIdentity.Unknown -> false
    }

    private companion object {
        const val TAG = "LD/discovery"
        // Room for GATT retries: a first attempt failing with status 133 or a timeout is common.
        const val RESOLVE_TIMEOUT_MS = 30_000L
    }
}
