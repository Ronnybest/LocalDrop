package dev.localdrop.feature.share

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.lifecycle.lifecycleScope
import dev.localdrop.R
import dev.localdrop.app.LocalDropApplication
import dev.localdrop.app.MainActivity
import dev.localdrop.app.ui.LocalDropTheme
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.device.defaultDevice
import dev.localdrop.feature.settings.NotificationAccess
import dev.localdrop.feature.transfer.TransferService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Target of `ACTION_SEND` / `ACTION_SEND_MULTIPLE`, both as the "LocalDrop" app target and as
 * Direct Share targets (one per trusted Mac), and of `ACTION_PROCESS_TEXT` ("Send to Mac" for
 * selected text). It has no screen of its own: it hands the shared
 * items to [TransferService] and finishes. UI appears only when a choice is unavoidable.
 */
class ShareTargetActivity : ComponentActivity() {

    private var pending: Pair<TrustedDevice, Shared>? = null

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        pending?.let { (device, shared) -> send(device, shared) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shared = parse(intent)
        if (shared == null) {
            Log.w(TAG, "Share intent without content: ${intent.action}")
            finish()
            return
        }
        val container = (application as LocalDropApplication).container
        lifecycleScope.launch {
            val macs = withContext(Dispatchers.IO) {
                container.trustedDeviceStore.load()
                container.trustedDeviceStore.devices.value
            }
            val shortcutId = intent.getStringExtra(ShortcutManagerCompat.EXTRA_SHORTCUT_ID)
            // A Direct Share target names its Mac; the plain LocalDrop target goes to the default one.
            val target = shortcutId?.let { id -> macs.firstOrNull { it.deviceId == id } } ?: macs.defaultDevice()
            when {
                target != null -> send(target, shared)
                macs.isEmpty() -> showNoDevices()
                else -> showPicker(macs, shared)
            }
        }
    }

    private fun send(device: TrustedDevice, shared: Shared) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && needsNotificationPermission()) {
            pending = device to shared
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        Log.i(TAG, "Sending ${shared.uris.size} item(s)${if (shared.text != null) " + text" else ""} to ${device.deviceId}")
        try {
            TransferService.sendShared(this, device.deviceId, shared.uris, shared.text)
            ShortcutManagerCompat.reportShortcutUsed(this, device.deviceId)
        } catch (e: SecurityException) {
            // The sharing app gave this activity no access it may pass on to the transfer service.
            Log.w(TAG, "Shared items not accessible: ${e.message}")
            Toast.makeText(this, R.string.share_not_accessible, Toast.LENGTH_LONG).show()
        }
        finish()
    }

    /** Asked once: without it, progress and results would be invisible. Transfers work either way. */
    private fun needsNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || pending != null) return false
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return false
        if (NotificationAccess.asked(this)) return false
        NotificationAccess.markAsked(this)
        return true
    }

    private fun showPicker(macs: List<TrustedDevice>, shared: Shared) {
        setContent {
            LocalDropTheme {
                AlertDialog(
                    onDismissRequest = ::finish,
                    title = { Text(stringResource(R.string.share_pick_title)) },
                    text = {
                        Column {
                            macs.forEach { mac ->
                                ListItem(
                                    modifier = Modifier.clickable { send(mac, shared) },
                                    leadingContent = { Icon(painterResource(R.drawable.ic_laptop), contentDescription = null) },
                                    headlineContent = { Text(mac.deviceName) },
                                )
                            }
                        }
                    },
                    confirmButton = {},
                    dismissButton = { TextButton(onClick = ::finish) { Text(stringResource(R.string.action_cancel)) } },
                )
            }
        }
    }

    private fun showNoDevices() {
        setContent {
            LocalDropTheme {
                AlertDialog(
                    onDismissRequest = ::finish,
                    title = { Text(stringResource(R.string.share_no_devices_title)) },
                    text = { Text(stringResource(R.string.share_no_devices_body)) },
                    confirmButton = {
                        TextButton(onClick = {
                            startActivity(Intent(this, MainActivity::class.java))
                            finish()
                        }) { Text(stringResource(R.string.action_add_mac)) }
                    },
                    dismissButton = { TextButton(onClick = ::finish) { Text(stringResource(R.string.action_cancel)) } },
                )
            }
        }
    }

    private class Shared(val uris: List<Uri>, val text: String?)

    private fun parse(intent: Intent): Shared? {
        if (intent.action == Intent.ACTION_PROCESS_TEXT) {
            // Selected text; nothing is returned to the calling app, so its text stays unchanged.
            val selected = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.takeIf { it.isNotBlank() }
            return selected?.let { Shared(emptyList(), it) }
        }
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE -> IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> return null
        }
        // Text accompanies files as a caption in many apps; send it on its own only when there are no files.
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { uris.isEmpty() && it.isNotBlank() }
        return if (uris.isEmpty() && text == null) null else Shared(uris, text)
    }

    private companion object {
        const val TAG = "LD/share"
    }
}
