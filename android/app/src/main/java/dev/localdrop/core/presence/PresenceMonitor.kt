package dev.localdrop.core.presence

import android.net.InetAddresses
import android.os.SystemClock
import android.util.Log
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.device.TrustedDeviceStore
import dev.localdrop.core.discovery.AdvertisedIdentity
import dev.localdrop.core.discovery.AdvertisedStatus
import dev.localdrop.core.discovery.BleScanner
import dev.localdrop.core.discovery.BluetoothEnvironment
import dev.localdrop.core.discovery.GattEndpointReader
import dev.localdrop.core.discovery.GattReadException
import dev.localdrop.core.discovery.ScanFailedException
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.core.protocol.ProtocolConstants
import dev.localdrop.core.transport.LocalNetworks
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch

/** Presence of a trusted device (protocol.md §2.7). */
enum class Presence { Offline, Nearby, Reachable, Connected, Busy }

data class DevicePresence(
    /** Its private BLE token was seen recently: physically close and awake. */
    val nearby: Boolean,
    /**
     * Whether its current addresses (read over BLE while nearby) are on one of this phone's
     * networks; null when not known (not nearby, or the read failed).
     */
    val reachable: Boolean?,
    val busy: Boolean,
    /** False when Bluetooth can't be used, so [nearby] is unknown rather than false. */
    val bluetoothAvailable: Boolean,
) {
    val state: Presence
        get() = when {
            nearby && busy -> Presence.Busy
            nearby && reachable == true -> Presence.Reachable
            nearby -> Presence.Nearby
            else -> Presence.Offline
        }
}

/**
 * Presence of trusted Macs, computed while collected (the app's home screen is visible) — never
 * as a permanent background scan. "Nearby" comes only from a fresh private BLE token; network
 * reachability only from the Mac's current addresses, read over BLE when it is nearby. Nothing
 * is inferred from remembered addresses, which say nothing about whether the Mac is on.
 */
class PresenceMonitor(
    private val environment: BluetoothEnvironment,
    private val scanner: BleScanner,
    private val gattReader: GattEndpointReader,
    private val trustStore: TrustedDeviceStore,
    private val localNetworks: LocalNetworks,
) {
    private class Seen(val device: android.bluetooth.BluetoothDevice, val atElapsedMs: Long, val status: AdvertisedStatus)
    /** [failed]: the last read failed; [info] is then the previous good one, if any. */
    private class Snapshot(val info: EndpointInfo?, val atElapsedMs: Long, val failed: Boolean)

    fun observe(): Flow<Map<String, DevicePresence>> = channelFlow {
        val lastSeen = ConcurrentHashMap<String, Seen>()
        val snapshots = ConcurrentHashMap<String, Snapshot>()
        val bluetoothAvailable = environment.currentBlocker() == null
        if (bluetoothAvailable) {
            launch {
                try {
                    scanner.scan().collect { advertisement ->
                        val identity = advertisement.identity as? AdvertisedIdentity.PrivateToken ?: return@collect
                        val device = trustStore.devices.value.findByToken(identity.token, System.currentTimeMillis()) ?: return@collect
                        val previous = lastSeen.put(device.deviceId, Seen(advertisement.device, advertisement.seenAtElapsedMs, identity.status))
                        // Network came back, or the Mac reappeared (it may have moved): re-read its addresses
                        // right away. Busy → available keeps them; a transfer doesn't change networks.
                        val reappeared = previous == null || advertisement.seenAtElapsedMs - previous.atElapsedMs > STALE_MS
                        if (identity.status == AdvertisedStatus.Available && (reappeared || previous?.status == AdvertisedStatus.NoNetwork)) {
                            snapshots.remove(device.deviceId)
                        }
                    }
                } catch (e: ScanFailedException) {
                    Log.w(TAG, "Presence scan failed: ${e.message}")
                } catch (e: SecurityException) {
                    Log.w(TAG, "Presence scan lost permission: ${e.message}")
                }
            }
            launch {
                // One Endpoint Info read per nearby Mac, refreshed every minute: its addresses tell
                // whether it is on our network right now, and `busy` whether it can take a transfer.
                while (true) {
                    val now = SystemClock.elapsedRealtime()
                    for (device in trustStore.devices.value) {
                        val seen = lastSeen[device.deviceId]?.takeIf { now - it.atElapsedMs <= STALE_MS } ?: continue
                        // Without a network there's nothing to check; the advertised status says so.
                        if (seen.status != AdvertisedStatus.Available) continue
                        val snapshot = snapshots[device.deviceId]
                        // A failed read is retried soon: the first GATT connection after the Mac
                        // restarts advertising often fails, and "Nearby" would otherwise stick for 30 s.
                        val maxAge = if (snapshot?.failed == true) FAILED_READ_RETRY_MS else SNAPSHOT_MAX_AGE_MS
                        if (snapshot != null && now - snapshot.atElapsedMs < maxAge) continue
                        val info = read(device, seen.device)
                        // Keep the last good addresses through a failed refresh; an invalidation already dropped them.
                        snapshots[device.deviceId] = Snapshot(info ?: snapshots[device.deviceId]?.info, SystemClock.elapsedRealtime(), info == null)
                    }
                    delay(REFRESH_INTERVAL_MS)
                }
            }
        }
        while (true) {
            val now = SystemClock.elapsedRealtime()
            send(
                trustStore.devices.value.associate { device ->
                    val seen = lastSeen[device.deviceId]?.takeIf { now - it.atElapsedMs <= STALE_MS }
                    val info = snapshots[device.deviceId]?.info?.takeIf { seen?.status == AdvertisedStatus.Available }
                    device.deviceId to DevicePresence(
                        nearby = seen != null,
                        reachable = when (seen?.status) {
                            AdvertisedStatus.NoNetwork -> false
                            AdvertisedStatus.Available -> info?.let(::isOnOurNetwork)
                            AdvertisedStatus.Busy, null -> null
                        },
                        // The advertised letter is fresher than a snapshot that may predate the transfer.
                        busy = seen?.status == AdvertisedStatus.Busy,
                        bluetoothAvailable = bluetoothAvailable,
                    )
                },
            )
            delay(REFRESH_INTERVAL_MS)
        }
    }

    private suspend fun read(device: TrustedDevice, bleDevice: android.bluetooth.BluetoothDevice): EndpointInfo? = try {
        gattReader.read(bleDevice, device.presenceKey).takeIf { it.deviceId == device.deviceId }
    } catch (e: GattReadException) {
        Log.i(TAG, "Presence read of ${device.deviceId} failed: ${e.message}")
        null
    }

    private fun isOnOurNetwork(info: EndpointInfo): Boolean = info.addresses.any { text ->
        try {
            localNetworks.isLocal(InetAddresses.parseNumericAddress(text))
        } catch (e: IllegalArgumentException) {
            false
        }
    }

    private companion object {
        const val TAG = "LD/presence"
        const val REFRESH_INTERVAL_MS = 2_000L
        const val SNAPSHOT_MAX_AGE_MS = 30_000L
        const val FAILED_READ_RETRY_MS = 3_000L
        const val STALE_MS = ProtocolConstants.DEVICE_STALE_TIMEOUT_MS
    }
}
