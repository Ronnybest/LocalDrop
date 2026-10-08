package dev.localdrop.core.device

import android.content.Context
import android.util.Log
import androidx.core.content.edit
import dev.localdrop.core.protocol.ProtocolConstants
import dev.localdrop.core.transfer.TransferManager
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Tells each paired Mac what this phone can do whenever that changes (an update added
 * receiving, say), so nothing has to be sent first for a new feature to appear on the Mac.
 * Runs when LocalDrop opens; a Mac out of reach is told next time.
 */
class CapabilityAnnouncer(context: Context, private val store: TrustedDeviceStore, private val manager: TransferManager) {
    private val prefs = context.getSharedPreferences("capabilities", Context.MODE_PRIVATE)
    private val running = AtomicBoolean(false)
    private val current = ProtocolConstants.CAPABILITIES.sorted().joinToString(",")

    suspend fun announce() {
        if (!running.compareAndSet(false, true)) return
        try {
            store.load()
            for (mac in store.devices.value) {
                if (prefs.getString(mac.deviceId, null) == current) continue
                if (manager.exchangeInfo(mac)) {
                    prefs.edit { putString(mac.deviceId, current) }
                    Log.i(TAG, "${mac.deviceId} knows this phone's capabilities")
                }
            }
        } finally {
            running.set(false)
        }
    }

    private companion object {
        const val TAG = "LD/trust"
    }
}
