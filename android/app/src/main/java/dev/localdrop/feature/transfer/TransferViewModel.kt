package dev.localdrop.feature.transfer

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.localdrop.app.LocalDropApplication
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.core.transfer.TestDataSource
import dev.localdrop.core.transfer.TransferManager
import dev.localdrop.core.transfer.TransferState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class TransferViewModel(application: Application, private val transferManager: TransferManager) : AndroidViewModel(application) {

    val state: StateFlow<TransferState> = transferManager.state

    private val _testDataSize = MutableStateFlow(TestDataSource.SIZES.first())
    val testDataSize: StateFlow<Long> = _testDataSize.asStateFlow()

    fun selectTestDataSize(bytes: Long) {
        _testDataSize.value = bytes
    }

    /** Diagnostics transfers go through the same foreground service as shares. */
    fun sendTestData(deviceId: String) = TransferService.sendTestData(getApplication(), deviceId, _testDataSize.value)

    private val _pairingSession = MutableStateFlow(false)

    /** A session started from Add Mac: it has its own screen until it is over. */
    val pairingSession: StateFlow<Boolean> = _pairingSession.asStateFlow()

    init {
        viewModelScope.launch {
            transferManager.state.collect { if (it is TransferState.Idle) _pairingSession.value = false }
        }
    }

    fun pair(endpoint: EndpointInfo) {
        if (transferManager.pair(endpoint)) _pairingSession.value = true
    }

    fun confirmPairing() = transferManager.confirmPairing()

    fun declinePairing() = transferManager.declinePairing()

    fun cancel() = transferManager.cancel()

    fun acceptIncoming() = transferManager.acceptIncoming()

    fun declineIncoming() = transferManager.declineIncoming()

    fun dismiss() = transferManager.dismiss()

    companion object {
        val Factory = viewModelFactory {
            initializer {
                val application = this[APPLICATION_KEY] as LocalDropApplication
                TransferViewModel(application, application.container.transferManager)
            }
        }
    }
}
