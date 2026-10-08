package dev.localdrop.feature.share

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import dev.localdrop.R
import dev.localdrop.app.MainActivity
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.device.TrustedDeviceStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Publishes one Sharing Shortcut per trusted Mac so it appears directly in the Android Sharesheet
 * (Direct Share, API 29+). Kept in sync with the trust store: pairing adds a target, Forget removes it.
 * The share-target declaration lives in res/xml/shortcuts.xml.
 */
class ShareShortcuts(private val context: Context, private val trustStore: TrustedDeviceStore) {

    fun keepInSync(scope: CoroutineScope) {
        scope.launch {
            trustStore.devices
                .map { devices -> devices.map { Triple(it.deviceId, it.deviceName, it.isDefault) } }
                .distinctUntilChanged()
                .collect { sync(trustStore.devices.value) }
        }
    }

    private fun sync(devices: List<TrustedDevice>) {
        val limit = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context)
        // The default Mac first, then most recently used: the targets most likely wanted in the Sharesheet.
        val published = devices.sortedWith(compareByDescending<TrustedDevice> { it.isDefault }.thenByDescending { it.lastSeenMs }).take(limit)
        val wanted = published.map { it.deviceId }.toSet()
        val stale = ShortcutManagerCompat.getDynamicShortcuts(context).map { it.id }.filter { it !in wanted }
        if (stale.isNotEmpty()) ShortcutManagerCompat.removeLongLivedShortcuts(context, stale)
        published.forEachIndexed { rank, device ->
            ShortcutManagerCompat.pushDynamicShortcut(context, shortcut(device, rank))
        }
        Log.i(TAG, "Share targets: ${published.size} published, ${stale.size} removed")
    }

    private fun shortcut(device: TrustedDevice, rank: Int): ShortcutInfoCompat =
        ShortcutInfoCompat.Builder(context, device.deviceId)
            .setShortLabel(device.deviceName)
            .setLongLabel(context.getString(R.string.shortcut_send_to, device.deviceName))
            .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_shortcut_mac))
            // Required for every shortcut; also what a launcher long-press opens.
            .setIntent(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW))
            .setLongLived(true)
            .setRank(rank)
            .setCategories(setOf(CATEGORY_SEND_TO_DEVICE))
            .build()

    companion object {
        private const val TAG = "LD/share"
        const val CATEGORY_SEND_TO_DEVICE = "dev.localdrop.category.SEND_TO_DEVICE"
    }
}
