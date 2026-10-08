package dev.localdrop.core.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.core.protocol.ProtocolConstants
import dev.localdrop.core.transport.ConnectionException
import kotlin.coroutines.resume
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout

/**
 * Resolves a trusted Mac by its Bonjour name (= deviceId) on the local network
 * (protocol.md §2.4–2.5). A fallback: guest networks often block multicast.
 */
class BonjourResolver(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)

    /** @throws ConnectionException.NotNearby when the name doesn't resolve in time. */
    suspend fun resolve(device: TrustedDevice, timeoutMs: Long = RESOLVE_TIMEOUT_MS): EndpointInfo = try {
        withTimeout(timeoutMs) {
            val info = resolveService(NsdServiceInfo().apply {
                serviceName = device.deviceId
                serviceType = ProtocolConstants.BONJOUR_SERVICE_TYPE
            })
            val addresses = hostAddresses(info).mapNotNull { it.hostAddress }
            if (addresses.isEmpty() || info.port !in 1..65_535) throw ConnectionException.NotNearby()
            Log.i(TAG, "Resolved ${device.deviceId} over Bonjour: port ${info.port}, ${addresses.size} address(es)")
            EndpointInfo(
                protocolVersion = ProtocolConstants.VERSION,
                deviceId = device.deviceId,
                deviceName = device.deviceName,
                platform = "macos",
                port = info.port,
                addresses = addresses,
                fingerprint = device.fingerprint,
            )
        }
    } catch (e: TimeoutCancellationException) {
        throw ConnectionException.NotNearby()
    }

    /**
     * `resolveService` is deprecated from API 34 in favour of `registerServiceInfoCallback`, whose
     * unregister call needs an SDK extension not every device has; the old call works everywhere.
     */
    @Suppress("DEPRECATION")
    private suspend fun resolveService(query: NsdServiceInfo): NsdServiceInfo = suspendCancellableCoroutine { continuation ->
        nsd.resolveService(query, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                // Left to time out: "not found" and "multicast blocked" look alike here.
                Log.w(TAG, "Bonjour resolve failed: $errorCode")
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                if (continuation.isActive) continuation.resume(serviceInfo)
            }
        })
    }

    private fun hostAddresses(info: NsdServiceInfo) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        info.hostAddresses
    } else {
        @Suppress("DEPRECATION")
        listOfNotNull(info.host)
    }

    private companion object {
        const val TAG = "LD/discovery"
        const val RESOLVE_TIMEOUT_MS = 8_000L
    }
}
