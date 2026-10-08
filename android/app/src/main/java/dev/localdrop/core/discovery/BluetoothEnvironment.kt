package dev.localdrop.core.discovery

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import androidx.core.content.ContextCompat
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/** Why BLE discovery cannot run right now. Each case maps to a distinct user action. */
sealed interface DiscoveryBlocker {
    data object BluetoothLeUnsupported : DiscoveryBlocker
    data class PermissionsMissing(val permissions: List<String>) : DiscoveryBlocker
    data object BluetoothOff : DiscoveryBlocker

    /** Android 11 only: BLE scans return nothing while system location is disabled. */
    data object LocationOff : DiscoveryBlocker
}

/** Reads the device conditions BLE discovery depends on and reports when they change. */
class BluetoothEnvironment(private val context: Context) {

    private val bluetoothManager: BluetoothManager? = context.getSystemService(BluetoothManager::class.java)
    private val locationManager: LocationManager? = context.getSystemService(LocationManager::class.java)

    val adapter: BluetoothAdapter? get() = bluetoothManager?.adapter

    /** Returns the first blocker in the order the user has to resolve them, or null when ready. */
    fun currentBlocker(): DiscoveryBlocker? {
        val adapter = adapter
        if (adapter == null || !context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return DiscoveryBlocker.BluetoothLeUnsupported
        }
        val missing = requiredPermissions().filter {
            ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) return DiscoveryBlocker.PermissionsMissing(missing)
        if (!adapter.isEnabled) return DiscoveryBlocker.BluetoothOff
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && locationManager?.isLocationEnabled != true) {
            return DiscoveryBlocker.LocationOff
        }
        return null
    }

    /** Emits whenever Bluetooth or location state changes. */
    fun changes(): Flow<Unit> = callbackFlow {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                trySend(Unit)
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(LocationManager.MODE_CHANGED_ACTION)
        }
        ContextCompat.registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        awaitClose { context.unregisterReceiver(receiver) }
    }

    companion object {
        /**
         * Runtime permissions BLE discovery needs on this API level.
         * Android 12+: BLUETOOTH_SCAN (declared neverForLocation) and BLUETOOTH_CONNECT for GATT.
         * Android 11: ACCESS_FINE_LOCATION; BLUETOOTH/BLUETOOTH_ADMIN are install-time.
         */
        fun requiredPermissions(): List<String> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                listOf(Manifest.permission.ACCESS_FINE_LOCATION)
            }
    }
}
