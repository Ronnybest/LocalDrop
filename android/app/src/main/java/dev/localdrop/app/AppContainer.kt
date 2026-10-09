package dev.localdrop.app

import android.content.Context
import android.os.StatFs
import dev.localdrop.core.crypto.IdentityKey
import dev.localdrop.core.crypto.KeystoreIdentityKey
import dev.localdrop.core.device.LocalDevice
import dev.localdrop.core.device.CapabilityAnnouncer
import dev.localdrop.core.device.TrustedDeviceStore
import dev.localdrop.core.discovery.BleScanner
import dev.localdrop.core.discovery.BonjourResolver
import dev.localdrop.core.history.HistoryStore
import dev.localdrop.core.presence.PresenceMonitor
import dev.localdrop.core.queue.AvailabilityWatcher
import dev.localdrop.core.queue.OutgoingStore
import dev.localdrop.core.discovery.DeviceResolver
import dev.localdrop.feature.share.ShareShortcuts
import dev.localdrop.core.discovery.BluetoothEnvironment
import dev.localdrop.core.discovery.GattEndpointReader
import dev.localdrop.core.discovery.NearbyDiscovery
import dev.localdrop.core.transfer.TransferManager
import dev.localdrop.core.transport.HandshakeClient
import dev.localdrop.core.transport.LocalNetworks
import dev.localdrop.core.transport.PeerConnector
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Process-wide singletons, created once in [LocalDropApplication]. */
class AppContainer(context: Context) {
    private val appContext = context.applicationContext

    /** Outlives screens: active sessions belong to the process, not to an Activity. */
    val applicationScope = CoroutineScope(SupervisorJob())

    val localDevice: LocalDevice by lazy { LocalDevice.loadOrCreate(appContext) }

    /** Loaded on first use, from a background thread (Keystore I/O). Retried if it failed. */
    private val identityKey: IdentityKey by lazy { KeystoreIdentityKey.loadOrCreate() }

    /** In noBackupFilesDir: trust relationships must never be restored onto another device. */
    val trustedDeviceStore = TrustedDeviceStore(File(appContext.noBackupFilesDir, "trusted-devices.cbor"))

    val bluetoothEnvironment = BluetoothEnvironment(appContext)

    val nearbyDiscovery by lazy { NearbyDiscovery(bluetoothEnvironment, bleScanner, gattReader, trustedDeviceStore) }

    /**
     * Trusted Macs as Direct Share targets, kept in sync for the life of the process. Syncing starts
     * only after the store is loaded: syncing an empty, not-yet-loaded list would delete the
     * shortcuts and reset their ranking in the Sharesheet.
     */
    private val shareShortcuts = ShareShortcuts(appContext, trustedDeviceStore).also { shortcuts ->
        applicationScope.launch(Dispatchers.IO) {
            trustedDeviceStore.load()
            shortcuts.keepInSync(applicationScope)
        }
    }

    /** Registered at startup so LAN networks are known before the user picks a device. */
    private val localNetworks = LocalNetworks(appContext)

    /** Sends kept for later, in noBackupFilesDir: never backed up, never cleared as cache. */
    val outgoingStore = OutgoingStore(File(appContext.noBackupFilesDir, "outgoing"))

    /** Recent transfers for the home screen; this phone only, never backed up. */
    val historyStore = HistoryStore(File(appContext.noBackupFilesDir, "history.cbor"))

    val availabilityWatcher by lazy { AvailabilityWatcher(bluetoothEnvironment, bleScanner, trustedDeviceStore, localNetworks) }

    val presenceMonitor by lazy { PresenceMonitor(bluetoothEnvironment, bleScanner, gattReader, trustedDeviceStore, localNetworks) }

    private val bleScanner = BleScanner(bluetoothEnvironment)
    private val gattReader = GattEndpointReader(appContext)

    val capabilityAnnouncer by lazy { CapabilityAnnouncer(appContext, trustedDeviceStore, transferManager) }

    val transferManager: TransferManager by lazy {
        TransferManager(
            scope = applicationScope,
            resolver = DeviceResolver(bluetoothEnvironment, bleScanner, gattReader),
            bonjourResolver = BonjourResolver(appContext),
            connector = PeerConnector(localNetworks),
            handshakeClient = HandshakeClient(
                localDevice = localDevice,
                identityProvider = { identityKey },
                trustLookup = trustedDeviceStore::trustState,
            ),
            trustStore = trustedDeviceStore,
            contentResolver = appContext.contentResolver,
            // Downloads lives on the primary external volume, like the app's external files dir.
            freeSpace = { appContext.getExternalFilesDir(null)?.let { StatFs(it.path).availableBytes } ?: 0L },
        )
    }
}
