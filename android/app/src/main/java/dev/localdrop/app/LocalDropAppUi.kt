package dev.localdrop.app

import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
    // The screens fade over the theme's own background, never the window's.
    Surface(color = MaterialTheme.colorScheme.background) {
        NavDisplay(
            backStack = backStack,
            onBack = ::back,
            transitionSpec = { sharedAxisX(forward = true) },
            popTransitionSpec = { sharedAxisX(forward = false) },
            // Under the back gesture the screen shrinks toward the swipe, Home standing still behind it.
            predictivePopTransitionSpec = {
                EnterTransition.None togetherWith scaleOut(targetScale = PREDICTIVE_SCALE)
            },
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
}

/**
 * Material's shared axis X between screens: the old one fades out quickly while moving a little,
 * the new one slides in the same way and fades in after it — never both half-visible at once.
 */
private fun sharedAxisX(forward: Boolean): ContentTransform {
    val sign = if (forward) 1 else -1
    val enter = slideInHorizontally(tween(AXIS_MS, easing = FastOutSlowInEasing)) { sign * it / AXIS_SHIFT } +
        fadeIn(tween(AXIS_MS - AXIS_FADE_OUT_MS, delayMillis = AXIS_FADE_OUT_MS, easing = LinearOutSlowInEasing))
    val exit = slideOutHorizontally(tween(AXIS_MS, easing = FastOutSlowInEasing)) { -sign * it / AXIS_SHIFT } +
        fadeOut(tween(AXIS_FADE_OUT_MS, easing = FastOutLinearInEasing))
    return enter togetherWith exit
}

private const val AXIS_MS = 300
private const val AXIS_FADE_OUT_MS = 90

/** The screens move a tenth of the width: enough to show direction, not a slide across. */
private const val AXIS_SHIFT = 10
private const val PREDICTIVE_SCALE = 0.9f
