package dev.localdrop.feature.devices

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.text.format.DateUtils
import androidx.annotation.RequiresApi
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.edit
import dev.localdrop.feature.clipboard.ClipboardTileService
import dev.localdrop.core.wake.CompanionLink
import android.util.Log
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.localdrop.R
import dev.localdrop.app.LocalDropApplication
import dev.localdrop.core.crypto.fingerprintDisplay
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.device.TrustedDeviceStore
import dev.localdrop.core.presence.DevicePresence
import dev.localdrop.core.presence.PresenceMonitor
import dev.localdrop.core.queue.OutgoingStore
import kotlinx.coroutines.flow.map
import androidx.compose.ui.res.pluralStringResource
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class HomeViewModel(private val store: TrustedDeviceStore, presenceMonitor: PresenceMonitor, outgoingStore: OutgoingStore) : ViewModel() {
    val devices: StateFlow<List<TrustedDevice>> = store.devices

    /** Kept sends per deviceId, counted in items (files or a text). */
    val waiting: StateFlow<Map<String, Int>> = outgoingStore.items
        .map { items -> items.groupBy { it.deviceId }.mapValues { (_, sends) -> sends.sumOf { it.itemCount } } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    /** Scans only while the screen is visible (5 s grace for configuration changes). */
    val presence: StateFlow<Map<String, DevicePresence>> = presenceMonitor.observe()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    fun setReceiveAutomatically(deviceId: String, enabled: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                store.setReceiveAutomatically(deviceId, enabled)
            } catch (e: IOException) {
                Log.e("LD/trust", "Could not save the receive setting for $deviceId", e)
            }
        }
    }

    fun makeDefault(deviceId: String) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                store.setDefault(deviceId)
            } catch (e: IOException) {
                Log.e("LD/trust", "Could not make $deviceId default", e)
            }
        }
    }

    fun forget(deviceId: String) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                store.forget(deviceId)
            } catch (e: IOException) {
                Log.e("LD/trust", "Could not forget $deviceId", e)
            }
        }
    }

    companion object {
        val Factory = viewModelFactory {
            initializer {
                val container = (this[APPLICATION_KEY] as LocalDropApplication).container
                HomeViewModel(container.trustedDeviceStore, container.presenceMonitor, container.outgoingStore)
            }
        }
    }
}

/** Android 13+ can add the clipboard tile from the app; older versions only via the Quick Settings editor. */
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
@Composable
private fun AddTileButton() {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences(TILE_PREFS, Context.MODE_PRIVATE) }
    var added by remember { mutableStateOf(prefs.getBoolean(KEY_TILE_ADDED, false)) }
    if (added) return
    val label = stringResource(R.string.tile_clipboard_label)
    TextButton(
        modifier = Modifier.padding(horizontal = 8.dp),
        onClick = {
            context.getSystemService(StatusBarManager::class.java).requestAddTileService(
                ComponentName(context, ClipboardTileService::class.java),
                label,
                Icon.createWithResource(context, R.drawable.ic_tile_clipboard),
                context.mainExecutor,
            ) { result ->
                Log.i("LD/clipboard", "Add tile result: $result")
                if (result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                    result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED
                ) {
                    prefs.edit { putBoolean(KEY_TILE_ADDED, true) }
                    added = true
                }
            }
        },
    ) { Text(stringResource(R.string.action_add_tile)) }
}

private const val TILE_PREFS = "tile"
private const val KEY_TILE_ADDED = "added"

@Composable
private fun DeviceMenu(
    canMakeDefault: Boolean,
    onMakeDefault: () -> Unit,
    onForget: () -> Unit,
    /** null when the Mac can't send to this phone. */
    receiveAutomatically: Boolean?,
    onReceiveAutomatically: (Boolean) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.action_more))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            if (canMakeDefault) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_make_default)) },
                    onClick = {
                        expanded = false
                        onMakeDefault()
                    },
                )
            }
            if (receiveAutomatically != null) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_receive_automatically)) },
                    trailingIcon = { Checkbox(checked = receiveAutomatically, onCheckedChange = null) },
                    onClick = {
                        expanded = false
                        onReceiveAutomatically(!receiveAutomatically)
                    },
                )
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.action_forget)) },
                onClick = {
                    expanded = false
                    onForget()
                },
            )
        }
    }
}

@Composable
private fun PresenceLine(presence: DevicePresence) {
    val (text, ready) = when {
        !presence.bluetoothAvailable -> stringResource(R.string.presence_unknown) to false
        !presence.nearby -> stringResource(R.string.presence_not_nearby) to false
        presence.busy -> stringResource(R.string.presence_nearby_busy) to false
        presence.reachable == true -> stringResource(R.string.presence_nearby_ready) to true
        presence.reachable == false -> stringResource(R.string.presence_nearby_other_network) to false
        else -> stringResource(R.string.presence_nearby) to true
    }
    Text(text, color = if (ready) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
}

/**
 * Management, not sending: sending happens from the Sharesheet. This screen exists for pairing,
 * forgetting and diagnostics, which are rare by design.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onAddMac: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    viewModel: HomeViewModel = viewModel(factory = HomeViewModel.Factory),
) {
    val devices by viewModel.devices.collectAsStateWithLifecycle()
    val presence by viewModel.presence.collectAsStateWithLifecycle()
    val waiting by viewModel.waiting.collectAsStateWithLifecycle()
    var pendingForget by remember { mutableStateOf<TrustedDevice?>(null) }
    val context = LocalContext.current
    // Receiving from a Mac in the background needs one companion-device approval (Android rule).
    var linked by remember { mutableStateOf(CompanionLink.isLinked(context)) }
    val linkApproval = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {
        linked = CompanionLink.isLinked(context)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
                actions = { TextButton(onClick = onOpenDiagnostics) { Text(stringResource(R.string.diagnostics_title)) } },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (devices.isEmpty()) {
                Card(Modifier.fillMaxWidth().padding(16.dp)) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(stringResource(R.string.home_empty_title), style = MaterialTheme.typography.titleMedium)
                        Text(stringResource(R.string.home_empty_body), style = MaterialTheme.typography.bodyMedium)
                        Button(onClick = onAddMac) { Text(stringResource(R.string.action_add_mac)) }
                    }
                }
            } else {
                val sender = devices.filter { it.canSend }.maxByOrNull { it.lastSeenMs }
                if (!linked && sender != null) {
                    Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(stringResource(R.string.receiving_needs_link_title, sender.deviceName), style = MaterialTheme.typography.titleMedium)
                            Text(stringResource(R.string.receiving_needs_link_body, sender.deviceName), style = MaterialTheme.typography.bodyMedium)
                            Button(onClick = {
                                CompanionLink.request(context, sender) { linkApproval.launch(IntentSenderRequest.Builder(it).build()) }
                            }) { Text(stringResource(R.string.action_allow)) }
                        }
                    }
                }
                Text(
                    stringResource(R.string.home_how_to_send),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
                Text(
                    stringResource(R.string.home_your_macs),
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
                LazyColumn(Modifier.weight(1f, fill = false)) {
                    items(devices, key = { it.deviceId }) { device ->
                        ListItem(
                            leadingContent = { Icon(painterResource(R.drawable.ic_laptop), contentDescription = null) },
                            headlineContent = {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(device.deviceName)
                                    // With one Mac it is the default anyway; the label matters only to tell several apart.
                                    if (devices.size > 1 && device.isDefault) {
                                        Text(
                                            stringResource(R.string.label_default),
                                            style = MaterialTheme.typography.labelMedium,
                                            color = MaterialTheme.colorScheme.primary,
                                        )
                                    }
                                }
                            },
                            supportingContent = {
                                Column {
                                    presence[device.deviceId]?.let { PresenceLine(it) }
                                    waiting[device.deviceId]?.let { count ->
                                        Text(
                                            pluralStringResource(R.plurals.home_waiting, count, count),
                                            color = MaterialTheme.colorScheme.tertiary,
                                        )
                                    }
                                    Text(
                                        stringResource(
                                            R.string.trusted_last_seen,
                                            DateUtils.getRelativeTimeSpanString(device.lastSeenMs).toString(),
                                        ),
                                    )
                                    Text(device.fingerprint.fingerprintDisplay(), fontFamily = FontFamily.Monospace)
                                }
                            },
                            trailingContent = {
                                DeviceMenu(
                                    canMakeDefault = devices.size > 1 && !device.isDefault,
                                    onMakeDefault = { viewModel.makeDefault(device.deviceId) },
                                    onForget = { pendingForget = device },
                                    receiveAutomatically = if (device.canSend) device.receiveAutomatically else null,
                                    onReceiveAutomatically = { viewModel.setReceiveAutomatically(device.deviceId, it) },
                                )
                            },
                        )
                    }
                }
                OutlinedButton(onClick = onAddMac, modifier = Modifier.padding(16.dp)) {
                    Text(stringResource(R.string.action_add_another_mac))
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) AddTileButton()
            }
        }
    }

    pendingForget?.let { device ->
        AlertDialog(
            onDismissRequest = { pendingForget = null },
            title = { Text(stringResource(R.string.trusted_forget_title, device.deviceName)) },
            text = { Text(stringResource(R.string.trusted_forget_body)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.forget(device.deviceId)
                    pendingForget = null
                }) { Text(stringResource(R.string.action_forget)) }
            },
            dismissButton = { TextButton(onClick = { pendingForget = null }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}
