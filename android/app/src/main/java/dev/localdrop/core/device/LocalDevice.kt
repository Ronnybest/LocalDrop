package dev.localdrop.core.device

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.edit
import java.util.UUID

/** Identity of this phone as other LocalDrop devices see it. */
data class LocalDevice(
    /**
     * Random UUID generated on first launch. Kept separate from the identity key so that
     * a key change of a known device can be detected (protocol/security.md §2).
     */
    val deviceId: String,
    val name: String,
) {
    companion object {
        private const val TAG = "LD/app"
        private const val PREFS = "local_device"
        private const val KEY_DEVICE_ID = "device_id"

        fun loadOrCreate(context: Context): LocalDevice {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val stored = prefs.getString(KEY_DEVICE_ID, null)?.takeIf { isValidUuid(it) }
            val deviceId = stored ?: UUID.randomUUID().toString().also {
                // commit(): the id must be durable before it is ever sent to a peer.
                prefs.edit(commit = true) { putString(KEY_DEVICE_ID, it) }
                Log.i(TAG, "Generated new deviceId $it")
            }
            return LocalDevice(deviceId, currentName(context))
        }

        /** The name from Settings › About phone › Device name, falling back to the model. */
        fun currentName(context: Context): String =
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
                ?.takeIf { it.isNotBlank() }
                ?: Build.MODEL

        private fun isValidUuid(value: String): Boolean =
            try {
                UUID.fromString(value)
                true
            } catch (e: IllegalArgumentException) {
                false
            }
    }
}
