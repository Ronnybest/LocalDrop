package dev.localdrop.feature.devices

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.text.format.DateUtils
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.edit
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.localdrop.R
import dev.localdrop.app.LocalDropApplication
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.device.TrustedDeviceStore
import dev.localdrop.core.device.defaultDevice
import dev.localdrop.core.history.HistoryEntry
import dev.localdrop.core.history.HistoryStore
import dev.localdrop.core.presence.DevicePresence
import dev.localdrop.core.presence.PresenceMonitor
import dev.localdrop.core.queue.OutgoingStore
import dev.localdrop.core.transfer.TransferState
import dev.localdrop.core.transfer.isFinal
import dev.localdrop.core.transfer.peerName
import dev.localdrop.core.wake.CompanionLink
import dev.localdrop.feature.clipboard.ClipboardTileService
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class HomeViewModel(
    private val store: TrustedDeviceStore,
    presenceMonitor: PresenceMonitor,
    outgoingStore: OutgoingStore,
    historyStore: HistoryStore,
) : ViewModel() {
    val devices: StateFlow<List<TrustedDevice>> = store.devices

    /** Kept sends per deviceId, counted in items (files or a text). */
    val waiting: StateFlow<Map<String, Int>> = outgoingStore.items
        .map { items -> items.groupBy { it.deviceId }.mapValues { (_, sends) -> sends.sumOf { it.itemCount } } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    /** Scans only while the screen is visible (5 s grace for configuration changes). */
    val presence: StateFlow<Map<String, DevicePresence>> = presenceMonitor.observe()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    val history: StateFlow<List<HistoryEntry>> = historyStore.entries

    init {
        viewModelScope.launch(Dispatchers.IO) { historyStore.load() }
    }

    fun setReceiveAutomatically(deviceId: String, enabled: Boolean) = save("receive setting") {
        store.setReceiveAutomatically(deviceId, enabled)
    }

    fun makeDefault(deviceId: String) = save("default Mac") { store.setDefault(deviceId) }

    fun forget(deviceId: String) = save("forget") { store.forget(deviceId) }

    private fun save(what: String, action: () -> Unit) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                action()
            } catch (e: IOException) {
                Log.e("LD/trust", "Could not save: $what", e)
            }
        }
    }

    companion object {
        val Factory = viewModelFactory {
            initializer {
                val container = (this[APPLICATION_KEY] as LocalDropApplication).container
                HomeViewModel(container.trustedDeviceStore, container.presenceMonitor, container.outgoingStore, container.historyStore)
            }
        }
    }
}

private const val TILE_PREFS = "tile"
private const val LINK_PREFS = "companion_link"
private const val KEY_LATER = "later"
private const val KEY_TILE_ADDED = "added"
private const val RECENT_COUNT = 5

/**
 * Built around the main Mac: its card says how it is and what is going on (a transfer with its
 * progress, a request to accept), and sends files or the clipboard. Below: one hint at a time,
 * recent transfers, the other Macs. A Mac's settings are in a sheet from its card or row.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    transfer: TransferState,
    onCancelTransfer: () -> Unit,
    onAcceptIncoming: () -> Unit,
    onDeclineIncoming: () -> Unit,
    onAddMac: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    viewModel: HomeViewModel = viewModel(factory = HomeViewModel.Factory),
) {
    val devices by viewModel.devices.collectAsStateWithLifecycle()
    val presence by viewModel.presence.collectAsStateWithLifecycle()
    val waiting by viewModel.waiting.collectAsStateWithLifecycle()
    val history by viewModel.history.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var sheetFor by remember { mutableStateOf<String?>(null) }
    var pendingForget by remember { mutableStateOf<TrustedDevice?>(null) }

    // Receiving from a Mac in the background needs one companion-device approval (Android rule).
    var linked by remember { mutableStateOf(CompanionLink.isLinked(context)) }
    val linkApproval = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {
        linked = CompanionLink.isLinked(context)
    }
    // The link can also be removed in Android's settings.
    LifecycleResumeEffect(Unit) {
        linked = CompanionLink.isLinked(context)
        onPauseOrDispose { }
    }
    fun requestLink(mac: TrustedDevice) {
        CompanionLink.request(context, mac) { linkApproval.launch(IntentSenderRequest.Builder(it).build()) }
    }

    // Files go to the Mac whose button was pressed; the picker's result doesn't say which.
    var filesTarget by remember { mutableStateOf<String?>(null) }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        val target = filesTarget
        if (target != null && uris.isNotEmpty()) SendFromHome.files(context, target, uris)
    }
    val onFiles = { deviceId: String ->
        filesTarget = deviceId
        pickFiles.launch(arrayOf("*/*"))
    }
    val onClipboard = { deviceId: String -> SendFromHome.clipboard(context, deviceId) }

    // A session under way belongs to the Mac it is with; pairing has its own screen.
    val active = transfer.takeIf { it !is TransferState.Idle && !it.isFinal() && it !is TransferState.Pairing }
    val main = devices.defaultDevice() ?: devices.maxByOrNull { it.lastSeenMs }
    val activeDeviceId = active?.let { state -> devices.firstOrNull { it.deviceName == state.peerName() }?.deviceId ?: main?.deviceId }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
                actions = {
                    IconButton(onClick = onOpenDiagnostics) {
                        Icon(Icons.Default.Settings, contentDescription = stringResource(R.string.diagnostics_title))
                    }
                },
            )
        },
    ) { padding ->
        if (main == null) {
            EmptyHome(onAddMac, Modifier.padding(padding))
            return@Scaffold
        }
        val others = devices.filter { it.deviceId != main.deviceId }
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(key = "main") {
                MacCard(
                    device = main,
                    presence = presence[main.deviceId],
                    waiting = waiting[main.deviceId] ?: 0,
                    transfer = active.takeIf { activeDeviceId == main.deviceId },
                    onFiles = { onFiles(main.deviceId) },
                    onClipboard = { onClipboard(main.deviceId) },
                    onMore = { sheetFor = main.deviceId },
                    onCancel = onCancelTransfer,
                    onAccept = onAcceptIncoming,
                    onDecline = onDeclineIncoming,
                )
            }
            item(key = "hint") {
                Hint(
                    linkFor = devices.filter { it.canSend }.maxByOrNull { it.lastSeenMs }?.takeIf { !linked },
                    onLink = ::requestLink,
                )
            }
            if (history.isNotEmpty()) {
                item(key = "recent") { SectionTitle(stringResource(R.string.home_recent)) }
                items(history.take(RECENT_COUNT), key = { "h${it.timeMs}${it.title}" }) { entry ->
                    HistoryRow(entry) { HistoryActions.open(context, entry) }
                }
            }
            item(key = "others") { SectionTitle(stringResource(R.string.home_other_macs)) }
            items(others, key = { it.deviceId }) { device ->
                val ongoing = active.takeIf { activeDeviceId == device.deviceId }
                if (ongoing != null) {
                    MacCard(
                        device = device,
                        presence = presence[device.deviceId],
                        waiting = waiting[device.deviceId] ?: 0,
                        transfer = ongoing,
                        onFiles = { onFiles(device.deviceId) },
                        onClipboard = { onClipboard(device.deviceId) },
                        onMore = { sheetFor = device.deviceId },
                        onCancel = onCancelTransfer,
                        onAccept = onAcceptIncoming,
                        onDecline = onDeclineIncoming,
                    )
                } else {
                    OtherMacRow(device, presence[device.deviceId], waiting[device.deviceId] ?: 0) { sheetFor = device.deviceId }
                }
            }
            item(key = "add") {
                ListItem(
                    headlineContent = { Text(stringResource(R.string.action_add_mac)) },
                    leadingContent = { RoundIcon(tint = MaterialTheme.colorScheme.surfaceContainerHighest) { Icon(Icons.Default.Add, null) } },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                    modifier = Modifier.clip28().clickable(onClick = onAddMac),
                )
            }
        }
    }

    devices.firstOrNull { it.deviceId == sheetFor }?.let { device ->
        MacSheet(
            device = device,
            canBeMain = devices.size > 1,
            linked = linked,
            onDismiss = { sheetFor = null },
            onMakeMain = { viewModel.makeDefault(device.deviceId) },
            onReceiveAutomatically = { viewModel.setReceiveAutomatically(device.deviceId, it) },
            onReceiveInBackground = { on ->
                if (on) {
                    requestLink(device)
                } else {
                    CompanionLink.unlink(context)
                    linked = CompanionLink.isLinked(context)
                }
            },
            onForget = {
                sheetFor = null
                pendingForget = device
            },
        )
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

@Composable
private fun EmptyHome(onAddMac: () -> Unit, modifier: Modifier) {
    Column(
        modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        RoundIcon(size = 96, tint = MaterialTheme.colorScheme.primaryContainer) {
            Icon(painterResource(R.drawable.ic_laptop), null, Modifier.size(44.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
        }
        Text(stringResource(R.string.home_empty_title), style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
        Text(
            stringResource(R.string.home_empty_body),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Button(onClick = onAddMac) { Text(stringResource(R.string.action_add_mac)) }
    }
}

/** A Mac with what it is doing; the main Mac always, any other one while a session runs with it. */
@Composable
private fun MacCard(
    device: TrustedDevice,
    presence: DevicePresence?,
    waiting: Int,
    transfer: TransferState?,
    onFiles: () -> Unit,
    onClipboard: () -> Unit,
    onMore: () -> Unit,
    onCancel: () -> Unit,
    onAccept: () -> Unit,
    onDecline: () -> Unit,
) {
    Card(
        shape = RoundedCornerShape(28.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                RoundIcon(size = 52, tint = MaterialTheme.colorScheme.primaryContainer) {
                    Icon(painterResource(R.drawable.ic_laptop), null, tint = MaterialTheme.colorScheme.onPrimaryContainer)
                }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onMore) { Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.action_more)) }
            }
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(device.deviceName, style = MaterialTheme.typography.titleLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                when (transfer) {
                    is TransferState.Receiving, is TransferState.AwaitingLocalDecision -> StatusPill(stringResource(R.string.card_receiving), highlighted = true)
                    null -> presence?.let { PresencePill(it) }
                    else -> StatusPill(stringResource(R.string.card_sending), highlighted = true)
                }
            }
            if (transfer != null) {
                TransferInCard(transfer, onCancel, onAccept, onDecline)
            } else {
                if (waiting > 0) {
                    Text(
                        pluralStringResource(R.plurals.home_waiting, waiting, waiting),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = onFiles, modifier = Modifier.weight(1f), contentPadding = ButtonDefaults.ButtonWithIconContentPadding) {
                        Icon(painterResource(R.drawable.ic_upload), null, Modifier.size(ButtonDefaults.IconSize))
                        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                        Text(stringResource(R.string.action_send_files))
                    }
                    FilledTonalButton(onClick = onClipboard, modifier = Modifier.weight(1f), contentPadding = ButtonDefaults.ButtonWithIconContentPadding) {
                        Icon(painterResource(R.drawable.ic_tile_clipboard), null, Modifier.size(ButtonDefaults.IconSize))
                        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                        Text(stringResource(R.string.action_send_clipboard))
                    }
                }
            }
        }
    }
}

@Composable
private fun PresencePill(presence: DevicePresence) {
    val (text, ready) = when {
        !presence.bluetoothAvailable -> stringResource(R.string.presence_unknown) to false
        !presence.nearby -> stringResource(R.string.presence_not_nearby) to false
        presence.busy -> stringResource(R.string.presence_nearby_busy) to false
        presence.reachable == true -> stringResource(R.string.presence_nearby_ready) to true
        presence.reachable == false -> stringResource(R.string.presence_nearby_other_network) to false
        else -> stringResource(R.string.presence_nearby) to true
    }
    StatusPill(text, highlighted = ready)
}

@Composable
private fun StatusPill(text: String, highlighted: Boolean) {
    val container = if (highlighted) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHighest
    val content = if (highlighted) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant
    Surface(shape = CircleShape, color = container, contentColor = content) {
        Row(Modifier.padding(horizontal = 10.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.size(6.dp).background(if (highlighted) MaterialTheme.colorScheme.primary else content, CircleShape))
            Text(text, style = MaterialTheme.typography.labelMedium)
        }
    }
}

/** One suggestion at a time: background receiving first, then the clipboard tile. */
@Composable
private fun Hint(linkFor: TrustedDevice?, onLink: (TrustedDevice) -> Unit) {
    val context = LocalContext.current
    val linkPrefs = remember { context.getSharedPreferences(LINK_PREFS, Context.MODE_PRIVATE) }
    val tilePrefs = remember { context.getSharedPreferences(TILE_PREFS, Context.MODE_PRIVATE) }
    var linkLater by remember { mutableStateOf(linkPrefs.getBoolean(KEY_LATER, false)) }
    var tileDone by remember { mutableStateOf(tilePrefs.getBoolean(KEY_TILE_ADDED, false) || tilePrefs.getBoolean(KEY_LATER, false)) }

    if (linkFor != null && !linkLater) {
        HintCard(
            title = stringResource(R.string.receiving_needs_link_title, linkFor.deviceName),
            body = stringResource(R.string.receiving_needs_link_body),
            detail = stringResource(R.string.receiving_link_scope),
            action = stringResource(R.string.action_allow),
            onAction = { onLink(linkFor) },
            onLater = {
                linkLater = true
                linkPrefs.edit { putBoolean(KEY_LATER, true) }
            },
        )
    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !tileDone) {
        val label = stringResource(R.string.tile_clipboard_label)
        HintCard(
            title = stringResource(R.string.tile_hint_title),
            body = stringResource(R.string.tile_hint_body),
            action = stringResource(R.string.action_add),
            onAction = {
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
                        tilePrefs.edit { putBoolean(KEY_TILE_ADDED, true) }
                        tileDone = true
                    }
                }
            },
            onLater = {
                tileDone = true
                tilePrefs.edit { putBoolean(KEY_LATER, true) }
            },
        )
    }
}

@Composable
private fun HintCard(title: String, body: String, action: String, onAction: () -> Unit, onLater: () -> Unit, detail: String? = null) {
    Card(
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Column(Modifier.padding(start = 20.dp, end = 12.dp, top = 16.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(end = 8.dp))
            Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(end = 8.dp))
            if (detail != null) {
                Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(end = 8.dp))
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onLater) { Text(stringResource(R.string.action_later)) }
                TextButton(onClick = onAction) { Text(action) }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 8.dp, top = 12.dp),
    )
}

@Composable
private fun HistoryRow(entry: HistoryEntry, onClick: () -> Unit) {
    val title = when {
        entry.kind == HistoryEntry.Kind.FILES && entry.count > 1 -> pluralStringResource(R.plurals.notification_files, entry.count, entry.count)
        entry.kind == HistoryEntry.Kind.TEXT && entry.title.isBlank() -> stringResource(R.string.history_text)
        else -> entry.title
    }
    val direction = stringResource(if (entry.incoming) R.string.notification_from else R.string.notification_towards, entry.peerName)
    val time = relativeTime(entry.timeMs)
    val image = entry.mimeType?.startsWith("image/") == true || entry.mimeType?.startsWith("video/") == true
    val canOpen = entry.incoming || entry.kind != HistoryEntry.Kind.FILES
    ListItem(
        headlineContent = { Text(title, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) },
        supportingContent = { Text(stringResource(R.string.history_line, direction, time), maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingContent = {
            RoundIcon(
                size = 40,
                shape = RoundedCornerShape(12.dp),
                tint = if (image) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHighest,
            ) {
                Icon(
                    painterResource(
                        when {
                            entry.kind == HistoryEntry.Kind.LINK -> R.drawable.ic_link
                            entry.kind == HistoryEntry.Kind.TEXT -> R.drawable.ic_text
                            image -> R.drawable.ic_image
                            else -> R.drawable.ic_file
                        },
                    ),
                    null,
                    Modifier.size(20.dp),
                    tint = if (image) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.clip28().then(if (canOpen) Modifier.clickable(onClick = onClick) else Modifier),
    )
}

@Composable
private fun OtherMacRow(device: TrustedDevice, presence: DevicePresence?, waiting: Int, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(device.deviceName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            val status = when {
                waiting > 0 -> pluralStringResource(R.plurals.home_waiting, waiting, waiting)
                presence?.nearby == true -> stringResource(R.string.presence_nearby)
                else -> stringResource(R.string.trusted_last_seen, relativeTime(device.lastSeenMs))
            }
            Text(status, maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        leadingContent = {
            RoundIcon(tint = MaterialTheme.colorScheme.surfaceContainerHighest) {
                Icon(painterResource(R.drawable.ic_laptop), null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.clip28().clickable(onClick = onClick),
    )
}

@Composable
internal fun RoundIcon(
    size: Int = 40,
    tint: Color,
    shape: Shape = CircleShape,
    content: @Composable () -> Unit,
) {
    Surface(shape = shape, color = tint, modifier = Modifier.size(size.dp)) {
        Box(contentAlignment = Alignment.Center) { content() }
    }
}

/** Rows are rounded where they light up when pressed. */
private fun Modifier.clip28() = clip(RoundedCornerShape(28.dp))

/** "just now" under a minute (rather than "0 minutes ago"), then "5 minutes ago", "yesterday"… */
@Composable
internal fun relativeTime(timeMs: Long): String {
    val now = System.currentTimeMillis()
    return if (now - timeMs < DateUtils.MINUTE_IN_MILLIS) {
        stringResource(R.string.time_just_now)
    } else {
        DateUtils.getRelativeTimeSpanString(timeMs, now, DateUtils.MINUTE_IN_MILLIS).toString()
    }
}
