package dev.localdrop.core.wake

import android.Manifest
import android.annotation.SuppressLint
import android.app.ForegroundServiceStartNotAllowedException
import android.app.PendingIntent
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.localdrop.R
import dev.localdrop.app.LocalDropApplication
import dev.localdrop.core.discovery.BluetoothEnvironment
import dev.localdrop.core.protocol.ProtocolConstants
import dev.localdrop.feature.transfer.TransferService

/**
 * A Bluetooth scan the system keeps running for LocalDrop while the app isn't: when a paired Mac
 * starts advertising a pending delivery (protocol.md §2.8), the result arrives as a broadcast to
 * [MacWakeReceiver], also with the app closed and the screen off. Filtered in the Bluetooth
 * controller and reported once per appearance, so it costs next to nothing.
 *
 * The system drops the scan when Bluetooth turns off or the phone restarts; it is registered
 * again on boot, after an update, and whenever LocalDrop runs.
 */
object MacWakeScan {
    private const val TAG = "LD/wake"
    private const val REQUEST_CODE = 41

    @SuppressLint("MissingPermission") // Checked through BluetoothEnvironment.currentBlocker.
    fun register(context: Context, environment: BluetoothEnvironment) {
        val blocker = environment.currentBlocker()
        if (blocker != null) {
            Log.i(TAG, "Not watching for Macs with files: $blocker")
            return
        }
        val scanner = environment.adapter?.bluetoothLeScanner ?: return
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(ProtocolConstants.PENDING_DELIVERY_UUID)).build())
        // Every match, not FIRST_MATCH: the controller's found/lost tracking reported a Mac
        // starting a delivery only now and then (on a Pixel 8, Android 17). The filter runs in the
        // controller, so nothing is reported while no Mac has files; the receiver drops repeats.
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()
        try {
            val intent = pendingIntent(context)
            scanner.stopScan(intent)
            val status = scanner.startScan(filters, settings, intent)
            if (status != 0) Log.w(TAG, "Wake scan not registered: status $status") else Log.i(TAG, "Watching for Macs with files")
        } catch (e: SecurityException) {
            Log.w(TAG, "Wake scan not allowed: ${e.message}")
        } catch (e: IllegalStateException) {
            Log.w(TAG, "Wake scan unavailable (Bluetooth turning off?): ${e.message}")
        }
    }

    // The system fills in the scan results, so the PendingIntent must be mutable.
    private fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQUEST_CODE,
        Intent(context, MacWakeReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )
}

/**
 * A Mac advertises files for a phone. Starts receiving at once when Android allows it (a
 * companion-device association with the Mac); otherwise asks with a notification, which starts
 * the transfer when tapped.
 */
class MacWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val error = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
        if (error != 0) {
            Log.w(TAG, "Wake scan error $error")
            return
        }
        // A pending delivery is advertised many times a second; one start is enough.
        val now = SystemClock.elapsedRealtime()
        if (now - lastWakeAt < REPEAT_INTERVAL_MS) return
        lastWakeAt = now
        Log.i(TAG, "A Mac has files for this phone")
        try {
            TransferService.receive(context)
        } catch (e: IllegalStateException) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || e !is ForegroundServiceStartNotAllowedException) throw e
            Log.i(TAG, "No companion association: asking with a notification")
            notifyTapToReceive(context)
        }
    }

    private fun notifyTapToReceive(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        TransferService.createChannels(context)
        val store = (context.applicationContext as LocalDropApplication).container.trustedDeviceStore
        val name = store.devices.value.filter { it.canSend }.maxByOrNull { it.lastSeenMs }?.deviceName
            ?: context.getString(R.string.notification_unknown_device)
        val notification = NotificationCompat.Builder(context, TransferService.CHANNEL_INCOMING)
            .setSmallIcon(R.drawable.ic_stat_localdrop)
            .setContentTitle(context.getString(R.string.notification_incoming_tap, name))
            .setContentText(context.getString(R.string.notification_incoming_tap_text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(TransferService.receiveOnTap(context))
            .build()
        NotificationManagerCompat.from(context).notify(TransferService.INCOMING_NOTIFICATION_ID, notification)
    }

    private companion object {
        const val TAG = "LD/wake"
        const val REPEAT_INTERVAL_MS = 15_000L

        /** Per process; a new process (after the app was closed) starts receiving at once. */
        @Volatile
        var lastWakeAt = Long.MIN_VALUE / 2
    }
}

/** The system forgets the wake scan on restart and on app update. */
class WakeScanRestorer : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val container = (context.applicationContext as LocalDropApplication).container
        container.trustedDeviceStore.load()
        if (container.trustedDeviceStore.devices.value.isNotEmpty()) MacWakeScan.register(context, container.bluetoothEnvironment)
    }
}
