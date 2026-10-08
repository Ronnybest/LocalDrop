package dev.localdrop.feature.settings

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.localdrop.R
import dev.localdrop.core.discovery.DiscoveryBlocker

private const val TAG = "LD/app"

/** Explains why discovery can't run and offers the one action that fixes it. */
@Composable
fun DiscoveryBlockerCard(blocker: DiscoveryBlocker, onResolved: () -> Unit) {
    when (blocker) {
        DiscoveryBlocker.BluetoothLeUnsupported -> MessageCard(
            title = stringResource(R.string.blocker_unsupported_title),
            body = stringResource(R.string.blocker_unsupported_body),
        )
        is DiscoveryBlocker.PermissionsMissing -> PermissionsCard(blocker.permissions, onResolved)
        DiscoveryBlocker.BluetoothOff -> BluetoothOffCard(onResolved)
        DiscoveryBlocker.LocationOff -> {
            val context = LocalContext.current
            MessageCard(
                title = stringResource(R.string.blocker_location_off_title),
                body = stringResource(R.string.blocker_location_off_body),
                actionLabel = stringResource(R.string.action_open_location_settings),
                onAction = { context.startSettings(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) },
            )
        }
    }
}

@Composable
private fun PermissionsCard(permissions: List<String>, onResolved: () -> Unit) {
    val context = LocalContext.current
    // After one denied request without a rationale, Android won't show the dialog again
    // ("Don't ask again"); the only path left is the app's settings page.
    var permanentlyDenied by rememberSaveable { mutableStateOf(false) }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        val denied = result.filterValues { granted -> !granted }.keys
        val activity = context.findActivity()
        permanentlyDenied = denied.isNotEmpty() && activity != null &&
            denied.none { activity.shouldShowRequestPermissionRationale(it) }
        Log.i(TAG, "Permission result: granted=${result.filterValues { it }.keys}, denied=$denied")
        onResolved()
    }

    val body = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        stringResource(R.string.blocker_permissions_body_nearby)
    } else {
        stringResource(R.string.blocker_permissions_body_location)
    }

    if (permanentlyDenied) {
        MessageCard(
            title = stringResource(R.string.blocker_permissions_title),
            body = body + "\n\n" + stringResource(R.string.blocker_permissions_denied_hint),
            actionLabel = stringResource(R.string.action_open_app_settings),
            onAction = {
                context.startSettings(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                )
            },
        )
    } else {
        MessageCard(
            title = stringResource(R.string.blocker_permissions_title),
            body = body,
            actionLabel = stringResource(R.string.action_allow),
            onAction = { launcher.launch(permissions.toTypedArray()) },
        )
    }
}

@Composable
private fun BluetoothOffCard(onResolved: () -> Unit) {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        onResolved()
    }
    MessageCard(
        title = stringResource(R.string.blocker_bluetooth_off_title),
        body = stringResource(R.string.blocker_bluetooth_off_body),
        actionLabel = stringResource(R.string.action_turn_on_bluetooth),
        onAction = { launcher.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)) },
    )
}

@Composable
fun MessageCard(
    title: String,
    body: String,
    actionLabel: String? = null,
    onAction: () -> Unit = {},
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(body, style = MaterialTheme.typography.bodyMedium)
            if (actionLabel != null) {
                Button(onClick = onAction) { Text(actionLabel) }
            }
        }
    }
}

private fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}

private fun Context.startSettings(intent: Intent) {
    try {
        startActivity(intent)
    } catch (e: ActivityNotFoundException) {
        Log.e(TAG, "No activity for ${intent.action}", e)
    }
}
