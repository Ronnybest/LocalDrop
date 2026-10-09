package dev.localdrop.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.localdrop.core.transfer.TransferState
import dev.localdrop.feature.devices.AddDeviceScreen
import dev.localdrop.feature.devices.HomeScreen
import dev.localdrop.feature.settings.DiagnosticsScreen
import dev.localdrop.feature.transfer.TransferScreen
import dev.localdrop.feature.transfer.TransferViewModel

private enum class Screen { Home, AddMac, Diagnostics }

/** Home with the Macs; Add Mac and Diagnostics on top of it. */
@Composable
fun LocalDropAppUi(transferViewModel: TransferViewModel = viewModel(factory = TransferViewModel.Factory)) {
    val transfer by transferViewModel.state.collectAsStateWithLifecycle()
    val testDataSize by transferViewModel.testDataSize.collectAsStateWithLifecycle()
    var screen by rememberSaveable { mutableStateOf(Screen.Home) }

    // Sending and receiving show on the home screen, in the Mac's card. Pairing, and a session
    // started from Add Mac, take over the screen while they last.
    val pairing = transfer is TransferState.Pairing || transfer is TransferState.Paired ||
        (screen == Screen.AddMac && transfer !is TransferState.Idle)
    if (pairing) {
        TransferScreen(
            state = transfer,
            onConfirmPairing = transferViewModel::confirmPairing,
            onDeclinePairing = transferViewModel::declinePairing,
            onCancel = transferViewModel::cancel,
            onAcceptIncoming = transferViewModel::acceptIncoming,
            onDeclineIncoming = transferViewModel::declineIncoming,
            onDismiss = {
                if (transfer is TransferState.Paired) screen = Screen.Home
                transferViewModel.dismiss()
            },
        )
        return
    }
    when (screen) {
        Screen.Home -> HomeScreen(
            transfer = transfer,
            onCancelTransfer = transferViewModel::cancel,
            onAcceptIncoming = transferViewModel::acceptIncoming,
            onDeclineIncoming = transferViewModel::declineIncoming,
            onAddMac = { screen = Screen.AddMac },
            onOpenDiagnostics = { screen = Screen.Diagnostics },
        )
        Screen.AddMac -> AddDeviceScreen(onPair = transferViewModel::pair, onBack = { screen = Screen.Home })
        Screen.Diagnostics -> DiagnosticsScreen(
            testDataSize = testDataSize,
            onTestDataSizeSelected = transferViewModel::selectTestDataSize,
            onSendTestData = transferViewModel::sendTestData,
            onBack = { screen = Screen.Home },
        )
    }
}
