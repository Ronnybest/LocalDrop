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

/** The app is for setup and management; an active session takes over the screen while it lasts. */
@Composable
fun LocalDropAppUi(transferViewModel: TransferViewModel = viewModel(factory = TransferViewModel.Factory)) {
    val transfer by transferViewModel.state.collectAsStateWithLifecycle()
    val testDataSize by transferViewModel.testDataSize.collectAsStateWithLifecycle()
    var screen by rememberSaveable { mutableStateOf(Screen.Home) }

    if (transfer !is TransferState.Idle) {
        TransferScreen(
            state = transfer,
            onConfirmPairing = transferViewModel::confirmPairing,
            onDeclinePairing = transferViewModel::declinePairing,
            onCancel = transferViewModel::cancel,
            onDismiss = {
                if (transfer is TransferState.Paired) screen = Screen.Home
                transferViewModel.dismiss()
            },
        )
        return
    }
    when (screen) {
        Screen.Home -> HomeScreen(
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
