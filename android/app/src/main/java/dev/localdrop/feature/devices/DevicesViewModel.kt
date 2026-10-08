package dev.localdrop.feature.devices

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import dev.localdrop.app.LocalDropApplication
import dev.localdrop.core.discovery.DiscoveryState
import dev.localdrop.core.discovery.NearbyDiscovery
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import dev.localdrop.core.device.TrustedDeviceStore

class DevicesViewModel(
    discovery: NearbyDiscovery,
    trustStore: TrustedDeviceStore,
    val localDeviceName: String,
) : ViewModel() {

    /** Identity key fingerprints of paired devices, matched against the BLE-advertised fingerprint. */
    val pairedFingerprints: StateFlow<Set<String>> = trustStore.devices
        .map { devices -> devices.mapTo(HashSet()) { it.fingerprint.toHexString() } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptySet())

    private val retries = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    /**
     * Discovery runs only while the screen is visible (5 s grace period for configuration
     * changes), so BLE scanning never continues in the background.
     */
    val state: StateFlow<DiscoveryState?> = discovery.discover(retries)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), initialValue = null)

    /** Re-evaluates permissions/Bluetooth state, e.g. after a permission dialog or a scan failure. */
    fun retry() {
        retries.tryEmit(Unit)
    }

    companion object {
        val Factory = viewModelFactory {
            initializer {
                val container = (this[APPLICATION_KEY] as LocalDropApplication).container
                DevicesViewModel(container.nearbyDiscovery, container.trustedDeviceStore, container.localDevice.name)
            }
        }
    }
}

internal fun ByteArray.toHexString(): String = joinToString("") { "%02x".format(it) }
