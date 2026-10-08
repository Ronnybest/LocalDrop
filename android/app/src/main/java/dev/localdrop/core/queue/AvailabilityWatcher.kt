package dev.localdrop.core.queue

import android.os.SystemClock
import android.util.Log
import dev.localdrop.core.device.TrustedDeviceStore
import dev.localdrop.core.discovery.AdvertisedIdentity
import dev.localdrop.core.discovery.AdvertisedStatus
import dev.localdrop.core.discovery.BleScanner
import dev.localdrop.core.discovery.BluetoothEnvironment
import dev.localdrop.core.discovery.ScanFailedException
import dev.localdrop.core.presence.findByToken
import dev.localdrop.core.protocol.ProtocolConstants
import dev.localdrop.core.transport.LocalNetworks
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** A moment when a waiting send may now succeed. */
sealed interface AvailabilityTrigger {
    /** The Mac's private token appeared, or its status turned to available (woke, got a network, finished a transfer). */
    data class DeviceAvailable(val deviceId: String) : AvailabilityTrigger

    /** This phone joined, left or switched a Wi-Fi/Ethernet network. */
    data object NetworkChanged : AvailabilityTrigger
}

/**
 * Watches for waiting sends: a BLE scan (low-latency for the first minutes, then balanced) for trusted Macs' tokens plus network changes.
 * Runs only while something waits (inside the transfer foreground service), never permanently.
 * Without Bluetooth only network changes are reported; the caller also retries on a timer.
 */
class AvailabilityWatcher(
    private val environment: BluetoothEnvironment,
    private val scanner: BleScanner,
    private val trustStore: TrustedDeviceStore,
    private val localNetworks: LocalNetworks,
) {
    private class Seen(val atElapsedMs: Long, val status: AdvertisedStatus)

    /**
     * @param closeWatchUntilMs elapsedRealtime until which to scan at low latency (most Macs are
     *   opened again within minutes of a send starting to wait); balanced afterwards.
     */
    fun triggers(closeWatchUntilMs: Long): Flow<AvailabilityTrigger> = channelFlow {
        launch {
            localNetworks.available.drop(1).collect { send(AvailabilityTrigger.NetworkChanged) }
        }
        val blocker = environment.currentBlocker()
        if (blocker != null) {
            Log.i(TAG, "Watching networks only: $blocker")
            return@channelFlow
        }
        launch {
            val lastSeen = HashMap<String, Seen>()
            try {
                while (true) {
                    // Android turns a scan running 30 min into an opportunistic one, so scans restart.
                    val closeLeft = closeWatchUntilMs - SystemClock.elapsedRealtime()
                    val close = closeLeft > 0
                    val window = if (close) closeLeft else RESCAN_INTERVAL_MS
                    withTimeoutOrNull(window) {
                        scanner.scan(background = !close).collect { advertisement ->
                            val identity = advertisement.identity as? AdvertisedIdentity.PrivateToken ?: return@collect
                            val device = trustStore.devices.value.findByToken(identity.token, System.currentTimeMillis()) ?: return@collect
                            val previous = lastSeen.put(device.deviceId, Seen(advertisement.seenAtElapsedMs, identity.status))
                            val reappeared = previous == null ||
                                advertisement.seenAtElapsedMs - previous.atElapsedMs > ProtocolConstants.DEVICE_STALE_TIMEOUT_MS
                            if (identity.status == AdvertisedStatus.Available && (reappeared || previous?.status != AdvertisedStatus.Available)) {
                                Log.i(TAG, "${device.deviceId} is available nearby")
                                send(AvailabilityTrigger.DeviceAvailable(device.deviceId))
                            }
                        }
                    }
                }
            } catch (e: ScanFailedException) {
                Log.w(TAG, "Watch scan failed: ${e.message}")
            } catch (e: SecurityException) {
                Log.w(TAG, "Watch scan lost permission: ${e.message}")
            } catch (e: CancellationException) {
                throw e
            } catch (e: IllegalStateException) {
                // Bluetooth turned off; network changes and the retry timer still apply.
                Log.w(TAG, "Watch scan stopped: ${e.message}")
            }
        }
    }

    private companion object {
        const val TAG = "LD/queue"
        const val RESCAN_INTERVAL_MS = 10 * 60_000L
    }
}
