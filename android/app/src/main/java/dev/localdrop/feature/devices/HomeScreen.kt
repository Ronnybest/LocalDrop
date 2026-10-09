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
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.material.icons.filled.Check
import androidx.compose.runtime.LaunchedEffect
import dev.localdrop.feature.history.historyGroup
import dev.localdrop.app.ui.Segments
import dev.localdrop.app.ui.segmentColors
import dev.localdrop.app.ui.segmentShape
import dev.localdrop.app.ui.segmentShapes
import androidx.compose.material3.SegmentedListItem
import dev.localdrop.feature.settings.Haptic
import dev.localdrop.feature.settings.rememberHaptics
import kotlinx.coroutines.delay
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material3.ButtonGroup
import androidx.compose.material3.ButtonGroupDefaults
import androidx.compose.material3.ButtonShapes
import androidx.compose.material3.LoadingIndicator
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
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.ui.input.nestedscroll.nestedScroll
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
import dev.localdrop.core.crypto.pairVerificationCode
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class HomeViewModel(
    private val store: TrustedDeviceStore,
    presenceMonitor: PresenceMonitor,
    outgoingStore: OutgoingStore,
    private val historyStore: HistoryStore,
    identityPublicKey: () -> ByteArray,
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

    private val ownKey = MutableStateFlow<ByteArray?>(null)

    /** Per Mac, the code both devices show for checking each other (security.md §2). */
    val verificationCodes: StateFlow<Map<String, String>> = combine(store.devices, ownKey) { devices, mine ->
        if (mine == null) emptyMap() else devices.associate { it.deviceId to pairVerificationCode(mine, it.publicKey) }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    init {
        viewModelScope.launch(Dispatchers.IO) {
            historyStore.load()
            ownKey.value = try {
                identityPublicKey()
            } catch (e: Exception) {
                Log.e("LD/trust", "Identity key unavailable for verification codes", e)
                null
            }
        }
    }

    fun setReceiveAutomatically(deviceId: String, enabled: Boolean) = save("receive setting") {
        store.setReceiveAutomatically(deviceId, enabled)
    }

    fun removeHistory(entry: HistoryEntry) {
        viewModelScope.launch(Dispatchers.IO) { historyStore.remove(entry.id) }
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
                HomeViewModel(
                    container.trustedDeviceStore,
                    container.presenceMonitor,
                    container.outgoingStore,
                    container.historyStore,
                    container::identityPublicKey,
                )
            }
        }
    }
}

private const val TILE_PREFS = "tile"
private const val LINK_PREFS = "companion_link"
private const val KEY_LATER = "later"
private const val KEY_TILE_ADDED = "added"
private const val RECENT_COUNT = 5
private const val REVEAL_DELAY_MS = 500L
private const val FINISHED_MS = 3_000L
private const val SPINNER_DELAY_MS = 500L
private const val CLIPBOARD_DONE_MS = 1_600L
private const val CLIPBOARD_SETTLE_MS = 400L
private const val CLIPBOARD_TIMEOUT_MS = 30_000L

private class ClipboardSend(val deviceId: String, val startedMs: Long) {
    /** The session started; when it ends without a history entry, the send didn't go now. */
    var sawSession = false
}

private enum class ClipboardState { IDLE, SENDING, DONE }

/** Files and the clipboard as one connected group: the pressed button widens, the other yields. */
@Composable
private fun SendButtons(clipboard: ClipboardState, onFiles: () -> Unit, onClipboard: () -> Unit) {
    val filesPress = remember { MutableInteractionSource() }
    val clipboardPress = remember { MutableInteractionSource() }
    ButtonGroup(
        overflowIndicator = {},
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(ButtonGroupDefaults.ConnectedSpaceBetween),
    ) {
        customItem(
            buttonGroupContent = {
                Button(
                    onClick = onFiles,
                    shapes = ButtonShapes(ButtonGroupDefaults.connectedLeadingButtonShape, ButtonGroupDefaults.connectedLeadingButtonPressShape),
                    interactionSource = filesPress,
                    modifier = Modifier.weight(1f).animateWidth(filesPress),
                    contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
                ) {
                    Icon(painterResource(R.drawable.ic_upload), null, Modifier.size(ButtonDefaults.IconSize))
                    Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                    Text(stringResource(R.string.action_send_files), maxLines = 1, softWrap = false)
                }
            },
            menuContent = {},
        )
        customItem(
            buttonGroupContent = {
                ClipboardButton(clipboard, onClipboard, clipboardPress, Modifier.weight(1f).animateWidth(clipboardPress))
            },
            menuContent = {},
        )
    }
}

/** "Clipboard", the expressive loading indicator while it goes (past half a second), then a check. */
@Composable
private fun ClipboardButton(state: ClipboardState, onClick: () -> Unit, interactionSource: MutableInteractionSource, modifier: Modifier) {
    var spinner by remember { mutableStateOf(false) }
    LaunchedEffect(state) {
        spinner = false
        if (state == ClipboardState.SENDING) {
            delay(SPINNER_DELAY_MS)
            spinner = true
        }
    }
    val shown = if (state == ClipboardState.SENDING && !spinner) ClipboardState.IDLE else state
    // Stays enabled-looking while busy: a greyed button would flash too.
    FilledTonalButton(
        onClick = { if (state == ClipboardState.IDLE) onClick() },
        shapes = ButtonShapes(ButtonGroupDefaults.connectedTrailingButtonShape, ButtonGroupDefaults.connectedTrailingButtonPressShape),
        interactionSource = interactionSource,
        modifier = modifier,
        contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
    ) {
        // The button keeps its size (no size animation, one line of text): the old state rolls up
        // and fades out while the new one rolls in from below.
        AnimatedContent(
            targetState = shown,
            modifier = Modifier.fillMaxWidth(),
            contentAlignment = Alignment.Center,
            transitionSpec = {
                (slideInVertically(tween(260)) { it / 2 } + fadeIn(tween(260))) togetherWith
                    (slideOutVertically(tween(200)) { -it / 2 } + fadeOut(tween(160))) using null
            },
            label = "clipboard",
        ) { current ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                when (current) {
                    ClipboardState.IDLE -> {
                        Icon(painterResource(R.drawable.ic_tile_clipboard), null, Modifier.size(ButtonDefaults.IconSize))
                        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                        Text(stringResource(R.string.action_send_clipboard), maxLines = 1, softWrap = false)
                    }
                    ClipboardState.SENDING -> LoadingIndicator(Modifier.size(24.dp), color = MaterialTheme.colorScheme.onSecondaryContainer)
                    ClipboardState.DONE -> {
                        Icon(Icons.Default.Check, null, Modifier.size(ButtonDefaults.IconSize))
                        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                        Text(stringResource(R.string.history_sent), maxLines = 1, softWrap = false)
                    }
                }
            }
        }
    }
}

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
    onOpenHistory: () -> Unit,
    viewModel: HomeViewModel = viewModel(factory = HomeViewModel.Factory),
) {
    val devices by viewModel.devices.collectAsStateWithLifecycle()
    val presence by viewModel.presence.collectAsStateWithLifecycle()
    val waiting by viewModel.waiting.collectAsStateWithLifecycle()
    val history by viewModel.history.collectAsStateWithLifecycle()
    val verificationCodes by viewModel.verificationCodes.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val haptic = rememberHaptics()
    var sheetFor by remember { mutableStateOf<String?>(null) }
    var pendingForget by remember { mutableStateOf<TrustedDevice?>(null) }
    var swiping by remember { mutableStateOf<String?>(null) }

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
        haptic(Haptic.TICK)
        filesTarget = deviceId
        pickFiles.launch(arrayOf("*/*"))
    }
    // Text from the clipboard goes in a moment: the button shows it (a spinner if it takes longer
    // than half a second, then a check) instead of the card flashing a transfer.
    var clipboardSend by remember { mutableStateOf<ClipboardSend?>(null) }
    var clipboardDone by remember { mutableStateOf<String?>(null) }
    val onClipboard = { deviceId: String ->
        haptic(Haptic.TICK)
        if (SendFromHome.clipboard(context, deviceId) == SendFromHome.Clipboard.TEXT) {
            clipboardSend = ClipboardSend(deviceId, System.currentTimeMillis())
        }
    }

    // A session under way belongs to the Mac it is with; pairing has its own screen.
    val active = transfer.takeIf { it !is TransferState.Idle && !it.isFinal() && it !is TransferState.Pairing }
    val main = devices.defaultDevice() ?: devices.maxByOrNull { it.lastSeenMs }
    val activeDeviceId = active?.let { state -> devices.firstOrNull { it.deviceName == state.peerName() }?.deviceId ?: main?.deviceId }

    clipboardSend?.let { send ->
        // Done once the send is in the history; over without it (failed, or queued for later),
        // the button goes back and the card or the notification says why.
        LaunchedEffect(send, history) {
            if (history.any { !it.incoming && it.timeMs >= send.startedMs }) {
                clipboardSend = null
                clipboardDone = send.deviceId
            }
        }
        LaunchedEffect(send, active == null) {
            if (active != null) {
                send.sawSession = true
            } else if (send.sawSession) {
                delay(CLIPBOARD_SETTLE_MS)
                if (clipboardSend === send) clipboardSend = null
            }
        }
        LaunchedEffect(send) {
            delay(CLIPBOARD_TIMEOUT_MS)
            if (clipboardSend === send) clipboardSend = null
        }
    }
    LaunchedEffect(clipboardDone) {
        if (clipboardDone != null) {
            haptic(Haptic.CONFIRM)
            delay(CLIPBOARD_DONE_MS)
            clipboardDone = null
        }
    }
    fun clipboardState(deviceId: String) = when {
        clipboardDone == deviceId -> ClipboardState.DONE
        clipboardSend?.deviceId == deviceId -> ClipboardState.SENDING
        else -> ClipboardState.IDLE
    }
    // A transfer of files that just finished is celebrated in its Mac's card for a moment: the
    // badge turns into a check, "Sent" or "Received" with what and how long. Only what finishes
    // while the screen is open.
    val openedAt = remember { System.currentTimeMillis() }
    var finished by remember { mutableStateOf<HistoryEntry?>(null) }
    val latest = history.firstOrNull()
    LaunchedEffect(latest?.id) {
        val entry = latest ?: return@LaunchedEffect
        if (entry.kind != HistoryEntry.Kind.FILES || entry.timeMs < openedAt) return@LaunchedEffect
        finished = entry
        haptic(Haptic.CONFIRM)
        delay(FINISHED_MS)
        if (finished?.id == entry.id) finished = null
    }
    fun finishedFor(device: TrustedDevice) = finished?.takeIf { it.peerName == device.deviceName }

    // The clipboard's own session shows on its button only.
    fun transferFor(deviceId: String) = active.takeIf { activeDeviceId == deviceId && clipboardSend?.deviceId != deviceId }

    // A large title that folds into a regular bar as the list scrolls.
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
                actions = {
                    IconButton(onClick = onOpenDiagnostics) {
                        Icon(Icons.Default.Settings, contentDescription = stringResource(R.string.settings_title))
                    }
                },
                scrollBehavior = scroll,
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
            // Rows of a group sit a hairline apart; cards and sections add their own space.
            verticalArrangement = Arrangement.spacedBy(Segments.Gap),
        ) {
            // Every row comes, goes and moves animated (fade and slide), deleted entries included.
            item(key = "main") {
                MacCard(
                    device = main,
                    presence = presence[main.deviceId],
                    waiting = waiting[main.deviceId] ?: 0,
                    transfer = transferFor(main.deviceId),
                    finished = finishedFor(main),
                    clipboard = clipboardState(main.deviceId),
                    onFiles = { onFiles(main.deviceId) },
                    onClipboard = { onClipboard(main.deviceId) },
                    onMore = { sheetFor = main.deviceId },
                    onCancel = { haptic(Haptic.REJECT); onCancelTransfer() },
                    onAccept = { haptic(Haptic.CONFIRM); onAcceptIncoming() },
                    onDecline = { haptic(Haptic.REJECT); onDeclineIncoming() },
                    modifier = Modifier.animateItem().padding(bottom = 10.dp),
                )
            }
            item(key = "hint") {
                Hint(
                    linkFor = devices.filter { it.canSend }.maxByOrNull { it.lastSeenMs }?.takeIf { !linked },
                    onLink = ::requestLink,
                    modifier = Modifier.animateItem(),
                )
            }
            item(key = "others") { SectionTitle(stringResource(R.string.home_other_macs), Modifier.animateItem()) }
            // Other Macs and "Add Mac" are one group; a Mac in a session leaves it as a card.
            val group = others.filter { transferFor(it.deviceId) == null && finishedFor(it) == null }
            others.filter { it !in group }.forEach { device ->
                item(key = device.deviceId) {
                    MacCard(
                        device = device,
                        presence = presence[device.deviceId],
                        waiting = waiting[device.deviceId] ?: 0,
                        transfer = transferFor(device.deviceId),
                        finished = finishedFor(device),
                        clipboard = clipboardState(device.deviceId),
                        onFiles = { onFiles(device.deviceId) },
                        onClipboard = { onClipboard(device.deviceId) },
                        onMore = { sheetFor = device.deviceId },
                        onCancel = { haptic(Haptic.REJECT); onCancelTransfer() },
                        onAccept = { haptic(Haptic.CONFIRM); onAcceptIncoming() },
                        onDecline = { haptic(Haptic.REJECT); onDeclineIncoming() },
                        modifier = Modifier.animateItem().padding(bottom = 10.dp),
                    )
                }
            }
            val rows = group.size + 1
            group.forEachIndexed { index, device ->
                item(key = device.deviceId) {
                    OtherMacRow(device, presence[device.deviceId], waiting[device.deviceId] ?: 0, segmentShape(index, rows), Modifier.animateItem()) {
                        sheetFor = device.deviceId
                    }
                }
            }
            item(key = "add") {
                SegmentedListItem(
                    onClick = { haptic(Haptic.TICK); onAddMac() },
                    shapes = segmentShapes(segmentShape(rows - 1, rows)),
                    colors = segmentColors(),
                    leadingContent = { RoundIcon(tint = MaterialTheme.colorScheme.primaryContainer) { Icon(Icons.Default.Add, null, tint = MaterialTheme.colorScheme.onPrimaryContainer) } },
                    modifier = Modifier.animateItem(),
                    content = { Text(stringResource(R.string.action_add_mac)) },
                )
            }
            if (history.isNotEmpty()) {
                item(key = "recent") { SectionTitle(stringResource(R.string.home_recent), Modifier.animateItem()) }
                historyGroup(
                    entries = history.take(RECENT_COUNT),
                    swiping = swiping,
                    onSwiping = { id, on -> swiping = if (on) id else swiping.takeIf { it != id } },
                    onOpen = { HistoryActions.open(context, it) },
                    onDelete = { viewModel.removeHistory(it) },
                )
                if (history.size > RECENT_COUNT) {
                    item(key = "all") {
                        Box(Modifier.animateItem().fillMaxWidth().padding(top = 6.dp), contentAlignment = Alignment.CenterEnd) {
                            FilledTonalButton(onClick = { haptic(Haptic.TICK); onOpenHistory() }) { Text(stringResource(R.string.action_show_all)) }
                        }
                    }
                }
            }
        }
    }

    devices.firstOrNull { it.deviceId == sheetFor }?.let { device ->
        MacSheet(
            device = device,
            canBeMain = devices.size > 1,
            verificationCode = verificationCodes[device.deviceId],
            linked = linked,
            onDismiss = { sheetFor = null },
            onMakeMain = {
                haptic(Haptic.TOGGLE_ON)
                viewModel.makeDefault(device.deviceId)
            },
            onReceiveAutomatically = {
                haptic(if (it) Haptic.TOGGLE_ON else Haptic.TOGGLE_OFF)
                viewModel.setReceiveAutomatically(device.deviceId, it)
            },
            onReceiveInBackground = { on ->
                haptic(if (on) Haptic.TOGGLE_ON else Haptic.TOGGLE_OFF)
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
                    haptic(Haptic.REJECT)
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

/** What a Mac's card shows below its name. */
private sealed interface CardMode {
    data object Idle : CardMode
    data class Busy(val transfer: TransferState) : CardMode
    data class Finished(val entry: HistoryEntry) : CardMode
}

/**
 * A Mac with what it is doing; the main Mac always, any other one while a session runs with it.
 * Its badge morphs with the state; the content below changes with a fade, the card's height
 * following with the theme's spring.
 */
@Composable
private fun MacCard(
    device: TrustedDevice,
    presence: DevicePresence?,
    waiting: Int,
    transfer: TransferState?,
    finished: HistoryEntry?,
    clipboard: ClipboardState,
    onFiles: () -> Unit,
    onClipboard: () -> Unit,
    onMore: () -> Unit,
    onCancel: () -> Unit,
    onAccept: () -> Unit,
    onDecline: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // What this phone starts shows only past half a second: quick sends don't flash the card.
    // The Mac's request and its files show at once.
    var revealed by remember { mutableStateOf(false) }
    LaunchedEffect(transfer != null) {
        revealed = false
        if (transfer != null) {
            delay(REVEAL_DELAY_MS)
            revealed = true
        }
    }
    val shown = transfer?.takeIf { revealed || it is TransferState.AwaitingLocalDecision || it is TransferState.Receiving }
    val mode = when {
        shown != null -> CardMode.Busy(shown)
        finished != null -> CardMode.Finished(finished)
        else -> CardMode.Idle
    }
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(32.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
    ) {
        Column(
            Modifier.animateContentSize(MaterialTheme.motionScheme.defaultSpatialSpec()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.Top) {
                MacAvatar(
                    when (mode) {
                        CardMode.Idle -> AvatarState.IDLE
                        is CardMode.Busy -> AvatarState.BUSY
                        is CardMode.Finished -> AvatarState.DONE
                    },
                )
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onMore) { Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.action_more)) }
            }
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(device.deviceName, style = MaterialTheme.typography.titleLargeEmphasized, maxLines = 2, overflow = TextOverflow.Ellipsis)
                when (shown) {
                    is TransferState.Receiving, is TransferState.AwaitingLocalDecision -> StatusPill(stringResource(R.string.card_receiving), highlighted = true)
                    null -> presence?.let { PresencePill(it) }
                    else -> StatusPill(stringResource(R.string.card_sending), highlighted = true)
                }
            }
            AnimatedContent(
                targetState = mode,
                contentKey = { it::class },
                transitionSpec = { fadeIn(tween(220, delayMillis = 60)) togetherWith fadeOut(tween(120)) using SizeTransform(clip = false) },
                label = "card",
            ) { current ->
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    when (current) {
                        is CardMode.Busy -> TransferInCard(current.transfer, onCancel, onAccept, onDecline)
                        is CardMode.Finished -> FinishedInCard(current.entry)
                        CardMode.Idle -> {
                            if (waiting > 0) {
                                Text(
                                    pluralStringResource(R.plurals.home_waiting, waiting, waiting),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            SendButtons(clipboard, onFiles, onClipboard)
                        }
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

private enum class HintKind { LINK, TILE, NONE }

/**
 * One suggestion at a time: background receiving first, then the clipboard tile. Answering one
 * fades it out and the next one, if any, in; the space closes smoothly.
 */
@Composable
private fun Hint(linkFor: TrustedDevice?, onLink: (TrustedDevice) -> Unit, modifier: Modifier) {
    val context = LocalContext.current
    val linkPrefs = remember { context.getSharedPreferences(LINK_PREFS, Context.MODE_PRIVATE) }
    val tilePrefs = remember { context.getSharedPreferences(TILE_PREFS, Context.MODE_PRIVATE) }
    var linkLater by remember { mutableStateOf(linkPrefs.getBoolean(KEY_LATER, false)) }
    var tileDone by remember { mutableStateOf(tilePrefs.getBoolean(KEY_TILE_ADDED, false) || tilePrefs.getBoolean(KEY_LATER, false)) }
    val kind = when {
        linkFor != null && !linkLater -> HintKind.LINK
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !tileDone -> HintKind.TILE
        else -> HintKind.NONE
    }
    AnimatedContent(
        targetState = kind,
        modifier = modifier,
        transitionSpec = {
            (fadeIn(tween(220, delayMillis = 90)) togetherWith fadeOut(tween(150))) using SizeTransform(clip = false)
        },
        label = "hint",
    ) { current ->
        when (current) {
            HintKind.LINK -> if (linkFor != null) HintCard(
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
            HintKind.TILE -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
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
            // An empty line in the list closes to nothing.
            HintKind.NONE -> Spacer(Modifier.fillMaxWidth())
        }
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
private fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = modifier.padding(start = 12.dp, top = 22.dp, bottom = 10.dp),
    )
}

@Composable
private fun OtherMacRow(device: TrustedDevice, presence: DevicePresence?, waiting: Int, shape: Shape, modifier: Modifier, onClick: () -> Unit) {
    SegmentedListItem(
        onClick = onClick,
        shapes = segmentShapes(shape),
        colors = segmentColors(),
        modifier = modifier,
        supportingContent = {
            val status = when {
                waiting > 0 -> pluralStringResource(R.plurals.home_waiting, waiting, waiting)
                presence?.nearby == true -> stringResource(R.string.presence_nearby)
                else -> stringResource(R.string.trusted_last_seen, relativeTime(device.lastSeenMs))
            }
            Text(status, maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        leadingContent = { MacAvatar(AvatarState.IDLE, size = 40.dp) },
        content = { Text(device.deviceName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
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
