package dev.localdrop.core.discovery

import android.os.SystemClock
import android.util.Log
import dev.localdrop.core.device.TrustedDeviceStore
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.core.protocol.ProtocolConstants
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** A LocalDrop device currently visible over BLE. */
data class NearbyDevice(
    /** Stable key: the advertised shortId, or the BLE address if the name wasn't advertised. */
    val key: String,
    val endpoint: EndpointState,
) {
    val displayName: String
        get() = when (endpoint) {
            is EndpointState.Resolved -> endpoint.info.deviceName
            is EndpointState.AlreadyPaired -> endpoint.name
            else -> "Dewlet device"
        }
}

sealed interface EndpointState {
    data object Resolving : EndpointState
    data class Resolved(val info: EndpointInfo) : EndpointState

    /** A Mac in pairing mode that this phone already trusts, recognized without any GATT read. */
    data class AlreadyPaired(val name: String) : EndpointState
    data class Failed(val reason: EndpointFailure) : EndpointState
}

enum class EndpointFailure {
    /** GATT connection or read failed (out of range, BLE stack error, timeout). */
    Unreachable,

    /** Endpoint Info didn't parse or doesn't match the advertisement. */
    InvalidData,

    /** The peer speaks a protocol version this app doesn't support. */
    IncompatibleVersion,
}

sealed interface DiscoveryState {
    data class Blocked(val blocker: DiscoveryBlocker) : DiscoveryState
    data class Scanning(val devices: List<NearbyDevice>) : DiscoveryState
    data class Failed(val message: String) : DiscoveryState
}

/**
 * Turns raw BLE advertisements into a list of nearby LocalDrop devices with resolved endpoints.
 * Collecting the flow runs discovery; cancelling it stops scanning.
 */
class NearbyDiscovery(
    private val environment: BluetoothEnvironment,
    private val scanner: BleScanner,
    private val gattReader: GattEndpointReader,
    private val trustStore: TrustedDeviceStore,
) {

    private data class Entry(
        val advertisement: Advertisement,
        val endpoint: EndpointState,
        val nextResolveAtElapsedMs: Long,
        val inFlight: Boolean,
        /** Consecutive unreachable reads; the first ones are routine on many BLE stacks. */
        val failures: Int = 0,
    )

    /** @param retries emits when the user asks to re-check permissions or retry after a failure. */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun discover(retries: Flow<Unit>): Flow<DiscoveryState> = channelFlow {
        merge(
            flowOf(Attempt(forced = true)),
            environment.changes().map { Attempt(forced = false) },
            retries.map { Attempt(forced = true) },
        )
            .map { it.copy(blocker = environment.currentBlocker()) }
            // Unrelated Bluetooth/location broadcasts must not restart a running scan;
            // explicit retries always do.
            .distinctUntilChanged { old, new -> old.blocker == new.blocker && !new.forced }
            .collectLatest { attempt ->
                val blocker = attempt.blocker
                if (blocker != null) {
                    Log.i(TAG, "Discovery blocked: $blocker")
                    send(DiscoveryState.Blocked(blocker))
                    return@collectLatest
                }
                try {
                    runScanSession { send(it) }
                } catch (e: ScanFailedException) {
                    send(DiscoveryState.Failed(e.message ?: "BLE scan failed"))
                } catch (e: SecurityException) {
                    Log.w(TAG, "Scan lost permission", e)
                    send(DiscoveryState.Blocked(environment.currentBlocker() ?: DiscoveryBlocker.PermissionsMissing(emptyList())))
                } catch (e: CancellationException) {
                    // A cancelled collection is not an unavailable scanner.
                    throw e
                } catch (e: IllegalStateException) {
                    Log.w(TAG, "Scanner unavailable", e)
                    send(DiscoveryState.Blocked(environment.currentBlocker() ?: DiscoveryBlocker.BluetoothOff))
                }
            }
    }

    private data class Attempt(val forced: Boolean, val blocker: DiscoveryBlocker? = null)

    private suspend fun runScanSession(emit: suspend (DiscoveryState) -> Unit) = coroutineScope {
        val entries = MutableStateFlow<Map<String, Entry>>(emptyMap())

        launch {
            entries.map { snapshot ->
                snapshot.values.map { it.toNearbyDevice() }.sortedWith(compareBy({ it.displayName }, { it.key }))
            }
                .distinctUntilChanged()
                .onStart { emit(DiscoveryState.Scanning(emptyList())) }
                .collect { emit(DiscoveryState.Scanning(it)) }
        }

        launch {
            while (true) {
                delay(STALE_CHECK_INTERVAL_MS)
                val now = SystemClock.elapsedRealtime()
                entries.update { current ->
                    current.filterValues { now - it.advertisement.seenAtElapsedMs <= ProtocolConstants.DEVICE_STALE_TIMEOUT_MS }
                        .also { kept ->
                            (current.keys - kept.keys).forEach { Log.i(TAG, "Device $it disappeared") }
                        }
                }
            }
        }

        // Only Macs in pairing mode can be added; private-mode Macs are recognizable by their
        // own trusted devices alone, so this list never shows them.
        scanner.scan().filter { it.identity is AdvertisedIdentity.Pairing }.collect { advertisement ->
            val key = advertisement.shortId ?: advertisement.device.address
            var shouldResolve = false
            entries.update { current ->
                val existing = current[key]
                val now = advertisement.seenAtElapsedMs
                val updated = when {
                    existing == null -> {
                        Log.i(TAG, "Found device $key (rssi ${advertisement.rssi})")
                        val trusted = advertisement.shortId?.let { shortId ->
                            trustStore.devices.value.firstOrNull { it.deviceId.replace("-", "").lowercase().startsWith(shortId) }
                        }
                        if (trusted != null) {
                            Entry(advertisement, EndpointState.AlreadyPaired(trusted.deviceName), now, inFlight = false)
                        } else {
                            shouldResolve = true
                            Entry(advertisement, EndpointState.Resolving, now, inFlight = true)
                        }
                    }
                    !existing.inFlight && existing.endpoint !is EndpointState.Resolved &&
                        existing.endpoint !is EndpointState.AlreadyPaired &&
                        existing.endpoint != EndpointState.Failed(EndpointFailure.InvalidData) &&
                        existing.endpoint != EndpointState.Failed(EndpointFailure.IncompatibleVersion) &&
                        now >= existing.nextResolveAtElapsedMs -> {
                        shouldResolve = true
                        existing.copy(advertisement = advertisement, inFlight = true)
                    }
                    else -> existing.copy(advertisement = advertisement)
                }
                current + (key to updated)
            }
            if (shouldResolve) {
                launch {
                    val endpoint = resolve(advertisement)
                    entries.update { current ->
                        val entry = current[key] ?: return@update current
                        val unreachable = endpoint == EndpointState.Failed(EndpointFailure.Unreachable)
                        val failures = if (unreachable) entry.failures + 1 else 0
                        // A first GATT attempt failing (status 133, timeout) is routine: keep showing
                        // "Connecting…" and retry quickly; report only a persistent failure.
                        val shown = if (unreachable && failures < VISIBLE_FAILURE_THRESHOLD) EndpointState.Resolving else endpoint
                        val delay = if (failures < VISIBLE_FAILURE_THRESHOLD) QUICK_RETRY_MS else RESOLVE_RETRY_INTERVAL_MS
                        current + (key to entry.copy(
                            endpoint = shown,
                            inFlight = false,
                            failures = failures,
                            nextResolveAtElapsedMs = SystemClock.elapsedRealtime() + delay,
                        ))
                    }
                }
            }
        }
    }

    private suspend fun resolve(advertisement: Advertisement): EndpointState = try {
        val info = gattReader.read(advertisement.device)
        when {
            advertisement.shortId?.let { !info.compactDeviceId.startsWith(it) } == true -> {
                Log.w(TAG, "Endpoint deviceId does not match advertised shortId ${advertisement.shortId}")
                EndpointState.Failed(EndpointFailure.InvalidData)
            }
            info.protocolVersion < ProtocolConstants.MIN_SUPPORTED_VERSION -> {
                Log.w(TAG, "Device ${info.deviceId} uses unsupported protocol v${info.protocolVersion}")
                EndpointState.Failed(EndpointFailure.IncompatibleVersion)
            }
            else -> {
                Log.i(
                    TAG,
                    "Resolved ${info.deviceId}: ${info.platform} v${info.protocolVersion}, " +
                        "port ${info.port}, ${info.addresses.size} address(es)",
                )
                EndpointState.Resolved(info)
            }
        }
    } catch (e: GattReadException.Malformed) {
        Log.w(TAG, "Invalid endpoint info from ${advertisement.shortId}: ${e.message}")
        EndpointState.Failed(EndpointFailure.InvalidData)
    } catch (e: GattReadException) {
        Log.w(TAG, "Cannot read endpoint info from ${advertisement.shortId}: ${e.message}")
        EndpointState.Failed(EndpointFailure.Unreachable)
    }

    private fun Entry.toNearbyDevice() = NearbyDevice(
        key = advertisement.shortId ?: advertisement.device.address,
        endpoint = endpoint,
    )

    private companion object {
        const val TAG = "LD/discovery"
        const val STALE_CHECK_INTERVAL_MS = 1_000L
        const val RESOLVE_RETRY_INTERVAL_MS = 10_000L
        const val QUICK_RETRY_MS = 2_000L
        const val VISIBLE_FAILURE_THRESHOLD = 3
    }
}
