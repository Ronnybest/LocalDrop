package dev.localdrop.core.transport

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketException
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Tracks Wi-Fi and Ethernet networks. Sockets to a peer are bound to one of these explicitly:
 * when Wi-Fi has no internet, Android routes unbound sockets over mobile data, which can't
 * reach a LAN address.
 */
class LocalNetworks(context: Context) {

    private val connectivity = context.getSystemService(ConnectivityManager::class.java)

    class LanNetwork(val network: Network, val linkAddresses: List<LinkAddress>)

    private val networks = ConcurrentHashMap<Network, LanNetwork>()
    private val _available = MutableStateFlow<Set<Network>>(emptySet())

    /** Joined Wi-Fi/Ethernet networks; changes when the phone joins, leaves or switches one. */
    val available: StateFlow<Set<Network>> = _available.asStateFlow()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            networks[network] = LanNetwork(network, linkProperties.linkAddresses)
            _available.value = networks.keys.toSet()
            Log.i(TAG, "LAN network $network: ${linkProperties.linkAddresses.joinToString()}")
        }

        override fun onLost(network: Network) {
            networks.remove(network)
            _available.value = networks.keys.toSet()
            Log.i(TAG, "LAN network $network lost")
        }
    }

    init {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            // A Wi-Fi without internet access is still a valid LAN for LocalDrop.
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.registerNetworkCallback(request, callback)
    }

    /** A VPN is up: its tunnel may carry, or block, what would otherwise go over the Wi-Fi. */
    fun vpnActive(): Boolean =
        connectivity.getNetworkCapabilities(connectivity.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true

    fun current(): List<LanNetwork> = networks.values.toList()

    /** An address/prefix on one of this phone's own interfaces (e.g. its hotspot). */
    class HostedSubnet(val interfaceName: String, val address: InetAddress, val prefixLength: Int)

    /**
     * Subnets on this phone's interfaces that aren't part of a joined network — in practice the
     * hotspot (or USB/Bluetooth tethering) the phone itself provides. Loopback and link-local are skipped.
     */
    fun hostedSubnets(networks: List<LanNetwork> = current()): List<HostedSubnet> {
        val joinedAddresses = networks.flatMap { network -> network.linkAddresses.map { it.address } }.toSet()
        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        } catch (e: SocketException) {
            Log.w(TAG, "Cannot enumerate network interfaces: ${e.message}")
            return emptyList()
        }
        return interfaces.filter { iface ->
            try {
                iface.isUp && !iface.isLoopback
            } catch (e: SocketException) {
                false
            }
        }.flatMap { iface ->
            iface.interfaceAddresses.mapNotNull { entry ->
                val address = entry.address ?: return@mapNotNull null
                if (address.isLinkLocalAddress || address.isLoopbackAddress || address in joinedAddresses) return@mapNotNull null
                HostedSubnet(iface.name, address, entry.networkPrefixLength.toInt())
            }
        }
    }

    /** Whether [address] is directly reachable: in a joined Wi-Fi/Ethernet subnet or this phone's hotspot. */
    fun isLocal(address: InetAddress): Boolean {
        val joined = current()
        return joined.any { network -> network.linkAddresses.any { inSubnet(it.address, it.prefixLength, address) } } ||
            hostedSubnets(joined).any { inSubnet(it.address, it.prefixLength, address) }
    }

    private companion object {
        const val TAG = "LD/connection"
    }
}

/** True if [other] lies in the subnet [own]/[prefixLength] (same address family). */
internal fun inSubnet(own: InetAddress, prefixLength: Int, other: InetAddress): Boolean {
    val ownBytes = own.address
    val target = other.address
    if (ownBytes.size != target.size) return false
    var bits = prefixLength
    for (i in ownBytes.indices) {
        if (bits <= 0) return true
        val mask = if (bits >= 8) 0xFF else (0xFF shl (8 - bits)) and 0xFF
        if ((ownBytes[i].toInt() and mask) != (target[i].toInt() and mask)) return false
        bits -= 8
    }
    return true
}
