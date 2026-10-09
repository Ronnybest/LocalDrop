package dev.localdrop.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavEntry
import androidx.navigation3.ui.NavDisplay
import dev.localdrop.core.transfer.TransferState
import dev.localdrop.feature.devices.AddDeviceScreen
import dev.localdrop.feature.devices.HomeScreen
import dev.localdrop.feature.history.HistoryScreen
import dev.localdrop.feature.settings.DiagnosticsScreen
import dev.localdrop.feature.transfer.TransferScreen
import dev.localdrop.feature.transfer.TransferViewModel

private enum class Screen { Home, AddMac, Diagnostics, History }

/**
 * Home with the Macs; Add Mac, Settings and all of Recent on top of it. Navigation 3 keeps the
 * stack and gives the system's transitions, predictive back included: the screen shrinks under
 * the back gesture with Home showing behind it.
 */
@Composable
fun LocalDropAppUi(transferViewModel: TransferViewModel = viewModel(factory = TransferViewModel.Factory)) {
    val transfer by transferViewModel.state.collectAsStateWithLifecycle()
    val testDataSize by transferViewModel.testDataSize.collectAsStateWithLifecycle()
    val pairingSession by transferViewModel.pairingSession.collectAsStateWithLifecycle()
    val backStack = rememberSaveable(
        saver = listSaver<SnapshotStateList<Screen>, String>(
            save = { stack -> stack.map { it.name } },
            restore = { names -> mutableStateListOf(*names.map(Screen::valueOf).toTypedArray()) },
        ),
    ) { mutableStateListOf(Screen.Home) }
    fun open(screen: Screen) = backStack.add(screen)
    fun back() {
        if (backStack.size > 1) backStack.removeAt(backStack.lastIndex)
    }

    // Sending and receiving show on the home screen, in the Mac's card, and go on behind other
    // screens. Pairing — comparing the code, or a session started from Add Mac — takes over the
    // screen while it lasts.
    val pairing = transfer is TransferState.Pairing || transfer is TransferState.Paired ||
        (pairingSession && transfer !is TransferState.Idle)
    if (pairing) {
        TransferScreen(
            state = transfer,
            onConfirmPairing = transferViewModel::confirmPairing,
            onDeclinePairing = transferViewModel::declinePairing,
            onCancel = transferViewModel::cancel,
            onAcceptIncoming = transferViewModel::acceptIncoming,
            onDeclineIncoming = transferViewModel::declineIncoming,
            onDismiss = {
                if (transfer is TransferState.Paired) {
                    backStack.clear()
                    backStack.add(Screen.Home)
                }
                transferViewModel.dismiss()
            },
        )
        return
    }
    NavDisplay(
        backStack = backStack,
        onBack = ::back,
        entryProvider = { screen ->
            when (screen) {
                Screen.Home -> NavEntry(screen) {
                    HomeScreen(
                        transfer = transfer,
                        onCancelTransfer = transferViewModel::cancel,
                        onAcceptIncoming = transferViewModel::acceptIncoming,
                        onDeclineIncoming = transferViewModel::declineIncoming,
                        onAddMac = { open(Screen.AddMac) },
                        onOpenDiagnostics = { open(Screen.Diagnostics) },
                        onOpenHistory = { open(Screen.History) },
                    )
                }
                Screen.History -> NavEntry(screen) { HistoryScreen(onBack = ::back) }
                Screen.AddMac -> NavEntry(screen) { AddDeviceScreen(onPair = transferViewModel::pair, onBack = ::back) }
                Screen.Diagnostics -> NavEntry(screen) {
                    DiagnosticsScreen(
                        testDataSize = testDataSize,
                        onTestDataSizeSelected = transferViewModel::selectTestDataSize,
                        onSendTestData = transferViewModel::sendTestData,
                        onBack = ::back,
                    )
                }
            }
        },
    )
}
