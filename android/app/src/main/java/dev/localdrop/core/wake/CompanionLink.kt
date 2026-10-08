package dev.localdrop.core.wake

import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.IntentSender
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.presence.PresenceCrypto
import dev.localdrop.core.protocol.ProtocolConstants

/**
 * A Companion Device Manager association with a paired Mac. The user approves it once in a
 * system dialog; with it, Android lets LocalDrop start receiving in the background when the Mac
 * has files for the phone — a plain background broadcast may not start a foreground service.
 * (Self-managed associations, which need no Bluetooth device, require a privileged permission.)
 */
object CompanionLink {
    private const val TAG = "LD/wake"

    fun isLinked(context: Context): Boolean {
        val manager = context.getSystemService(CompanionDeviceManager::class.java) ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.myAssociations.isNotEmpty()
        } else {
            @Suppress("DEPRECATION")
            manager.associations.isNotEmpty()
        }
    }

    /**
     * Asks Android to associate with [mac]. The system finds it over Bluetooth by its current
     * private name, so only this Mac is offered; [onIntent] launches the system dialog.
     */
    fun request(context: Context, mac: TrustedDevice, onIntent: (IntentSender) -> Unit) {
        val manager = context.getSystemService(CompanionDeviceManager::class.java) ?: return
        val request = AssociationRequest.Builder().setSingleDevice(true).apply {
            for (uuid in listOf(ProtocolConstants.SERVICE_UUID, ProtocolConstants.PENDING_DELIVERY_UUID)) {
                addDeviceFilter(filter(mac, uuid))
            }
        }.build()
        val callback = object : CompanionDeviceManager.Callback() {
            override fun onAssociationPending(intentSender: IntentSender) = onIntent(intentSender)

            override fun onAssociationCreated(associationInfo: AssociationInfo) {
                Log.i(TAG, "Linked with ${mac.deviceId}")
            }

            @Deprecated("Replaced by onAssociationPending on API 33")
            override fun onDeviceFound(intentSender: IntentSender) = onIntent(intentSender)

            override fun onFailure(error: CharSequence?) {
                Log.w(TAG, "Linking with ${mac.deviceId} failed: $error")
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.associate(request, context.mainExecutor, callback)
        } else {
            @Suppress("DEPRECATION")
            manager.associate(request, callback, null)
        }
    }

    /** This Mac's private names for the current token slot and its neighbours (protocol.md §2.2). */
    private fun filter(mac: TrustedDevice, uuid: java.util.UUID): BluetoothLeDeviceFilter {
        val builder = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(ScanFilter.Builder().setServiceUuid(ParcelUuid(uuid)).build())
        mac.presenceKey?.let { key ->
            val slot = PresenceCrypto.slot(System.currentTimeMillis())
            val tokens = (slot - 1..slot + 1).joinToString("|") { Regex.escape(PresenceCrypto.encodeToken(PresenceCrypto.token(key, it))) }
            builder.setNamePattern(java.util.regex.Pattern.compile("^[LNB](?:$tokens)$"))
            // Show the Mac's real name instead of its rotating Bluetooth name.
            try {
                builder.setRenameFromName(mac.deviceName, "", 0, 0)
            } catch (e: IllegalArgumentException) {
                Log.i(TAG, "Can't rename the Mac in the system dialog: ${e.message}")
            }
        }
        return builder.build()
    }
}
