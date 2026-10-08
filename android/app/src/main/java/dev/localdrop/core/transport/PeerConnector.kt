package dev.localdrop.core.transport

import android.net.InetAddresses
import android.util.Log
import dev.localdrop.core.protocol.EndpointInfo
import java.io.IOException
import java.net.ConnectException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.Socket
import java.net.SocketTimeoutException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/**
 * Opens a TCP connection to a peer's advertised endpoint over the local network.
 *
 * Two topologies are supported:
 * - both devices on the same Wi-Fi/Ethernet network: the socket is bound to that network, so it
 *   never leaks onto mobile data when the Wi-Fi has no internet;
 * - the peer joined this phone's own hotspot: the hotspot interface isn't a `Network` for apps, so
 *   the socket stays unbound and the kernel routes it through the directly attached subnet.
 */
class PeerConnector(private val localNetworks: LocalNetworks) {

    private sealed interface Route {
        /** Through a Wi-Fi/Ethernet network this phone has joined. */
        class ViaNetwork(val lan: LocalNetworks.LanNetwork) : Route {
            override fun toString() = "network ${lan.network}"
        }

        /** Through an interface this phone hosts, e.g. its hotspot. */
        class Direct(val interfaceName: String) : Route {
            override fun toString() = "local interface $interfaceName"
        }
    }

    private class Candidate(val address: InetAddress, val route: Route, val sameSubnet: Boolean)

    /** @param quick short timeouts, for a remembered endpoint that may be stale. */
    suspend fun connect(endpoint: EndpointInfo, quick: Boolean = false): Socket = withContext(Dispatchers.IO) {
        val networks = localNetworks.current()
        val hosted = localNetworks.hostedSubnets(networks)
        if (networks.isEmpty() && hosted.isEmpty()) throw ConnectionException.NoLocalNetwork()

        val candidates = candidates(endpoint, networks, hosted)
        if (candidates.isEmpty()) {
            // With only a hotspot and no matching address, the peer isn't on this phone's hotspot.
            if (networks.isEmpty()) throw ConnectionException.NoLocalNetwork()
            throw ConnectionException.Unreachable(IOException("peer advertised no usable address"))
        }

        var lastError: ConnectionException? = null
        for (candidate in candidates) {
            coroutineContext.ensureActive()
            val target = InetSocketAddress(candidate.address, endpoint.port)
            val socket = when (val route = candidate.route) {
                is Route.ViaNetwork -> route.lan.network.socketFactory.createSocket()
                is Route.Direct -> Socket()
            }
            try {
                socket.tcpNoDelay = true
                socket.keepAlive = true
                Log.i(TAG, "Connecting to $target via ${candidate.route} (same subnet: ${candidate.sameSubnet})")
                val timeout = when {
                    quick -> QUICK_TIMEOUT_MS
                    candidate.sameSubnet -> SAME_SUBNET_TIMEOUT_MS
                    else -> OTHER_TIMEOUT_MS
                }
                socket.connect(target, timeout)
                Log.i(TAG, "Connected to $target")
                return@withContext socket
            } catch (e: IOException) {
                closeQuietly(socket)
                lastError = when (e) {
                    is ConnectException -> ConnectionException.Refused(e)
                    is SocketTimeoutException, is NoRouteToHostException -> ConnectionException.Unreachable(e)
                    else -> ConnectionException.Unreachable(e)
                }
                Log.w(TAG, "Connect to $target failed: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
        throw lastError ?: ConnectionException.Unreachable(null)
    }

    /**
     * Same-subnet addresses first (spec §2.3), then other IPv4, then IPv6. Addresses outside every
     * known subnet are tried only through a joined network: unbound, they could go out over mobile data.
     */
    private fun candidates(
        endpoint: EndpointInfo,
        networks: List<LocalNetworks.LanNetwork>,
        hosted: List<LocalNetworks.HostedSubnet>,
    ): List<Candidate> = endpoint.addresses.mapNotNull { text ->
        val address = try {
            InetAddresses.parseNumericAddress(text)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Ignoring malformed address '$text'")
            return@mapNotNull null
        }
        val joined = networks.firstOrNull { network ->
            network.linkAddresses.any { inSubnet(it.address, it.prefixLength, address) }
        }
        val own = hosted.firstOrNull { inSubnet(it.address, it.prefixLength, address) }
        when {
            joined != null -> Candidate(address, Route.ViaNetwork(joined), sameSubnet = true)
            own != null -> Candidate(address, Route.Direct(own.interfaceName), sameSubnet = true)
            networks.isNotEmpty() -> Candidate(address, Route.ViaNetwork(networks.first()), sameSubnet = false)
            else -> null
        }
    }.sortedWith(compareBy({ !it.sameSubnet }, { it.address !is Inet4Address }))

    private fun closeQuietly(socket: Socket) {
        try {
            socket.close()
        } catch (e: IOException) {
            Log.w(TAG, "Error closing failed socket: ${e.message}")
        }
    }

    private companion object {
        const val TAG = "LD/connection"
        const val SAME_SUBNET_TIMEOUT_MS = 10_000
        const val OTHER_TIMEOUT_MS = 3_000
        const val QUICK_TIMEOUT_MS = 2_000
    }
}
