package dev.localdrop.feature.clipboard

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import dev.localdrop.R
import dev.localdrop.app.LocalDropApplication
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.device.defaultDevice
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Quick Settings tile "Clipboard → Mac". Android lets only the focused app read the clipboard
 * (API 29+), so a tap opens [ClipboardSendActivity], which reads it once it has focus.
 */
class ClipboardTileService : TileService() {

    private var scope: CoroutineScope? = null

    override fun onStartListening() {
        super.onStartListening()
        val scope = MainScope().also { scope = it }
        val store = (application as LocalDropApplication).container.trustedDeviceStore
        scope.launch {
            withContext(Dispatchers.IO) { store.load() }
            store.devices.collect(::update)
        }
    }

    override fun onStopListening() {
        scope?.cancel()
        scope = null
        super.onStopListening()
    }

    // The Intent overload is used only below API 34, where it is the only one.
    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val intent = Intent(this, ClipboardSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val launch = Runnable {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        }
        // The clipboard may hold something private: send it only from an unlocked phone.
        if (isLocked) unlockAndRun(launch) else launch.run()
    }

    private fun update(devices: List<TrustedDevice>) {
        val tile = qsTile ?: return
        tile.state = if (devices.isEmpty()) Tile.STATE_UNAVAILABLE else Tile.STATE_INACTIVE
        tile.subtitle = when {
            devices.isEmpty() -> getString(R.string.tile_no_mac)
            else -> devices.defaultDevice()?.deviceName ?: getString(R.string.tile_choose_mac)
        }
        tile.updateTile()
    }
}
