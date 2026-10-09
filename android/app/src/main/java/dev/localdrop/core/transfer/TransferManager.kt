package dev.localdrop.core.transfer

import android.content.ContentResolver
import android.os.SystemClock
import android.util.Log
import dev.localdrop.core.crypto.randomBytes
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.device.TrustedDeviceStore
import dev.localdrop.core.discovery.BonjourResolver
import dev.localdrop.core.discovery.DeviceResolver
import dev.localdrop.core.protocol.presenceKey
import dev.localdrop.core.protocol.CborValue
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.core.protocol.Message
import dev.localdrop.core.protocol.MessageType
import dev.localdrop.core.protocol.ProtocolConstants
import dev.localdrop.core.protocol.SessionStatus
import dev.localdrop.core.protocol.TransferMessages
import dev.localdrop.core.transport.ConnectionException
import dev.localdrop.core.transport.HandshakeClient
import dev.localdrop.core.transport.PeerConnector
import dev.localdrop.core.transport.PeerIdentity
import dev.localdrop.core.transport.SecureChannel
import dev.localdrop.core.transport.decoding
import java.io.IOException
import java.io.InputStream
import java.net.Socket
import java.security.MessageDigest
import dev.localdrop.core.protocol.ErrorCode
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

data class TransferSummary(val fileCount: Int, val totalBytes: Long, val firstFileName: String)

data class TransferProgress(
    val bytesSent: Long,
    val totalBytes: Long,
    val currentFileName: String,
    val fileIndex: Int,
    val fileCount: Int,
    val bytesPerSecond: Long,
    /** Over a longer window, for the time left: steadier than [bytesPerSecond]. */
    val averageBytesPerSecond: Long = bytesPerSecond,
    /** Every file's size in order, so progress can be shown file by file. */
    val fileSizes: List<Long> = emptyList(),
)

/**
 * Explicit transfer state (no boolean flags). Discovery happens before a transfer starts and is
 * modelled by `DiscoveryState` on the device list.
 */
sealed interface TransferState {
    data object Idle : TransferState
    data class Connecting(val peerName: String) : TransferState

    /** Both users compare [code]. [confirmedLocally] is set once this phone's user confirmed. */
    data class Pairing(val peer: PeerIdentity, val code: String, val keyChanged: Boolean, val confirmedLocally: Boolean) : TransferState
    data class Preparing(val peerName: String) : TransferState
    data class AwaitingApproval(val peerName: String, val summary: TransferSummary) : TransferState
    data class Transferring(val peerName: String, val progress: TransferProgress) : TransferState

    /** All data sent; waiting for the receiver to confirm SHA-256 and save. */
    data class Verifying(val peerName: String, val progress: TransferProgress) : TransferState
    data class Completed(val peerName: String, val summary: TransferSummary, val durationMs: Long) : TransferState

    /** Text was put on the receiver's clipboard. */
    data class TextCopied(val peerName: String) : TransferState

    /** The Mac offers files to this phone; its user decides (notification) unless the Mac is auto-accepted. */
    data class AwaitingLocalDecision(val peerName: String, val summary: TransferSummary) : TransferState
    data class Receiving(val peerName: String, val progress: TransferProgress) : TransferState

    /** Files from the Mac were saved in Downloads; [texts] go to the clipboard. */
    data class Received(val peerName: String, val files: List<ReceivedFile>, val texts: List<String> = emptyList()) : TransferState

    /** The Mac had nothing (more) for this phone, or everything was declined. */
    data class NothingReceived(val peerName: String) : TransferState

    /** Pair-only session finished; [newlyPaired] is false when the devices already trusted each other. */
    data class Paired(val peerName: String, val newlyPaired: Boolean) : TransferState
    data class Failed(val peerName: String, val error: ConnectionException) : TransferState
    data class Cancelled(val peerName: String, val byPeer: Boolean) : TransferState
}

/** Where a session goes: a device picked from a scan, or a trusted device found by identity. */
sealed interface SendTarget {
    val name: String

    class Endpoint(val info: EndpointInfo) : SendTarget {
        override val name: String get() = info.deviceName
    }

    class Trusted(val device: TrustedDevice) : SendTarget {
        override val name: String get() = device.deviceName
    }
}

/**
 * Runs one session at a time: resolve → connect → (pair) → request → stream → verify.
 * Transfers are driven by `TransferService` (foreground) so they survive the UI; pair-only
 * sessions run from the app while it is visible.
 */
class TransferManager(
    private val scope: CoroutineScope,
    private val resolver: DeviceResolver,
    private val bonjourResolver: BonjourResolver,
    private val connector: PeerConnector,
    private val handshakeClient: HandshakeClient,
    private val trustStore: TrustedDeviceStore,
    /** Where received files are saved (MediaStore Downloads). */
    private val contentResolver: ContentResolver,
    /** Free bytes on the volume that holds Downloads. */
    private val freeSpace: () -> Long,
) {
    private val _state = MutableStateFlow<TransferState>(TransferState.Idle)
    val state: StateFlow<TransferState> = _state.asStateFlow()

    private var job: Job? = null

    @Volatile
    private var channel: SecureChannel? = null

    @Volatile
    private var activeTransferId: ByteArray? = null

    /** The request awaiting the receiver's decision; [append] adds to it. Guarded by [requestLock]. */
    private class PendingRequest(val transferId: ByteArray, val deviceId: String, val files: MutableList<SourceFile>) {
        /** Shares added with `transfer_add`, in order, with how many files each brought. */
        val appended = mutableListOf<Pair<TransferSource, Int>>()
        var decided = false
    }

    private val requestLock = Any()
    private var pendingRequest: PendingRequest? = null

    @Volatile
    private var activeSource: TransferSource? = null

    @Volatile
    private var decidedParts: List<TransferSource>? = null

    /**
     * The shares the last session's outcome applies to: every part of its source, or — once the
     * receiver decided — the parts its decision covered. Shares added too late aren't included
     * and must be sent again.
     */
    val lastIncluded: List<TransferSource> get() = decidedParts ?: activeSource?.parts.orEmpty()

    /** Starts a transfer. Returns false if another session is in progress. */
    fun send(target: SendTarget, source: TransferSource): Boolean = start(target, source)

    /** Connects only to pair (or confirm existing trust); no transfer follows. */
    fun pair(endpoint: EndpointInfo): Boolean = start(SendTarget.Endpoint(endpoint), source = null)

    /**
     * Connects to a trusted Mac and takes what it has for this phone (protocol.md §2.8).
     * [autoAccept]: the user lets this Mac send without asking.
     */
    fun receive(device: TrustedDevice, autoAccept: Boolean): Boolean =
        start(SendTarget.Trusted(device), source = null, receive = ReceiveOptions(autoAccept))

    private class ReceiveOptions(val autoAccept: Boolean)

    /**
     * Connects to a trusted Mac only to exchange names and capabilities — after an update the
     * Mac learns this phone can receive, and the phone learns the Mac can send — without any
     * visible state. Separate from [state]: it may run next to a real session.
     */
    suspend fun exchangeInfo(device: TrustedDevice): Boolean = withContext(Dispatchers.IO) {
        val established = try {
            establish(SendTarget.Trusted(device))
        } catch (e: ConnectionException) {
            Log.i(TAG, "Info exchange with ${device.deviceId} failed: ${e.message}")
            return@withContext false
        }
        try {
            val session = established.session
            if (session.status != SessionStatus.Trusted) return@withContext false
            val peer = session.peer
            trustStore.markSeen(peer.deviceId, peer.name)
            trustStore.rememberSessionInfo(peer.deviceId, session.presenceKey, peer.capabilities)
            trustStore.rememberEndpoint(peer.deviceId, established.addresses, established.port)
            sendQuietly(session.channel, Message(MessageType.CLOSE))
            Log.i(TAG, "Exchanged info with ${peer.deviceId}: ${peer.capabilities}")
            true
        } finally {
            closeQuietly(established.socket)
        }
    }

    @Volatile
    private var pendingDecision: CompletableDeferred<Boolean>? = null

    /** This phone's user accepted the files the Mac offers. */
    fun acceptIncoming() {
        pendingDecision?.complete(true)
    }

    fun declineIncoming() {
        pendingDecision?.complete(false)
    }

    val isBusy: Boolean get() = _state.value.let { it !is TransferState.Idle && !it.isFinal() }

    private fun start(target: SendTarget, source: TransferSource?, receive: ReceiveOptions? = null): Boolean {
        val peerName = target.name
        val connecting = TransferState.Connecting(peerName)
        val current = _state.value
        if (current !is TransferState.Idle && !current.isFinal()) return false
        if (!_state.compareAndSet(current, connecting)) return false
        activeSource = source
        decidedParts = null

        job = scope.launch(Dispatchers.IO) {
            var socket: Socket? = null
            try {
                val established = establish(target)
                socket = established.socket
                val session = established.session
                ensureActive()
                channel = session.channel
                val peer = session.peer

                val newlyPaired = when (session.status) {
                    SessionStatus.Trusted -> {
                        trustStore.markSeen(peer.deviceId, peer.name)
                        // The Mac hands out its current presence key (it rotates after a Forget).
                        trustStore.rememberSessionInfo(peer.deviceId, session.presenceKey, peer.capabilities)
                        false
                    }
                    SessionStatus.PairingRequired, SessionStatus.KeyChanged -> {
                        // Receiving never pairs: the Mac stopped trusting this phone.
                        if (receive != null) throw ConnectionException.PeerError(ErrorCode.NOT_TRUSTED, null)
                        val pairing = TransferState.Pairing(peer, session.pairingCode, session.status == SessionStatus.KeyChanged, false)
                        if (!_state.compareAndSet(connecting, pairing)) return@launch
                        awaitPairingResult(session.channel, peer)
                        true
                    }
                }
                // Trust is settled here; next time, connect straight to this endpoint.
                trustStore.rememberEndpoint(peer.deviceId, established.addresses, established.port)
                if (receive != null) {
                    runReceive(session.channel, peer, receive)
                } else if (source == null) {
                    advance(TransferState.Paired(peer.name, newlyPaired))
                } else if (advance(TransferState.Preparing(peer.name))) {
                    val text = source.clipboardText
                    if (text != null && ProtocolConstants.CAP_CLIPBOARD_RECEIVE in peer.capabilities) {
                        runText(session.channel, peer.name, text)
                    } else {
                        runTransfer(session.channel, peer.deviceId, peer.name, source)
                    }
                }
                sendQuietly(session.channel, Message(MessageType.CLOSE))
            } catch (e: ConnectionException) {
                Log.w(TAG, "Transfer to $peerName ended: ${e.message}")
                _state.update { state ->
                    when {
                        state is TransferState.Idle || state is TransferState.Cancelled -> state
                        e is ConnectionException.CancelledByPeer -> TransferState.Cancelled(peerName, byPeer = true)
                        else -> TransferState.Failed(peerName, e)
                    }
                }
            } finally {
                synchronized(requestLock) { pendingRequest = null }
                channel = null
                activeTransferId = null
                // After a user cancel, cancel() sends `cancel` and closes the socket itself;
                // closing here could cut that message off.
                val cancelledLocally = (_state.value as? TransferState.Cancelled)?.byPeer == false
                if (!cancelledLocally) closeQuietly(socket)
            }
        }
        return true
    }

    private class Established(val socket: Socket, val session: HandshakeClient.Result, val addresses: List<String>, val port: Int)

    /**
     * Connects and authenticates. A trusted device is tried first at its remembered endpoint —
     * no Bluetooth needed, so a flaky BLE/GATT exchange can't block a send to a known Mac. If
     * that fails (or another device now has that address), Bluetooth discovery takes over. The
     * handshake signature, not the way the address was found, proves the peer's identity.
     */
    private suspend fun establish(target: SendTarget): Established {
        if (target is SendTarget.Trusted) {
            val device = target.device
            val port = device.lastPort
            if (port != null && device.lastAddresses.isNotEmpty()) {
                val remembered = EndpointInfo(
                    protocolVersion = ProtocolConstants.VERSION,
                    deviceId = device.deviceId,
                    deviceName = device.deviceName,
                    platform = "macos",
                    port = port,
                    addresses = device.lastAddresses,
                    fingerprint = device.fingerprint,
                )
                try {
                    return handshake(connector.connect(remembered, quick = true), remembered)
                } catch (e: ConnectionException) {
                    when (e) {
                        is ConnectionException.Refused, is ConnectionException.Unreachable, is ConnectionException.Timeout,
                        is ConnectionException.ConnectionLost, is ConnectionException.AuthenticationFailed,
                        -> Log.i(TAG, "Remembered endpoint of ${device.deviceId} failed (${e.message}); discovering over Bluetooth")
                        else -> throw e
                    }
                }
            }
            coroutineContext.ensureActive()
            val discovered = discover(device)
            return handshake(connector.connect(discovered), discovered)
        }
        val info = (target as SendTarget.Endpoint).info
        return handshake(connector.connect(info), info)
    }

    /**
     * BLE (presence token → Endpoint Info) and Bonjour race; the first endpoint wins. If both fail,
     * the BLE error is reported: it tells "not nearby" from "nearby but unresponsive".
     */
    private suspend fun discover(device: TrustedDevice): EndpointInfo = coroutineScope {
        val results = Channel<Pair<Boolean, Result<EndpointInfo>>>(capacity = 2)
        suspend fun attempt(isBle: Boolean, block: suspend () -> EndpointInfo) {
            val result = try {
                Result.success(block())
            } catch (e: ConnectionException) {
                Result.failure(e)
            }
            results.send(isBle to result)
        }
        val jobs = listOf(
            launch { attempt(true) { resolver.resolve(device) } },
            launch { attempt(false) { bonjourResolver.resolve(device) } },
        )
        var bleError: Throwable? = null
        var otherError: Throwable? = null
        repeat(jobs.size) {
            val (isBle, result) = results.receive()
            result.onSuccess { endpoint ->
                jobs.forEach { it.cancel() }
                return@coroutineScope endpoint
            }
            if (isBle) bleError = result.exceptionOrNull() else otherError = result.exceptionOrNull()
        }
        throw (bleError ?: otherError ?: ConnectionException.NotNearby())
    }

    private fun handshake(socket: Socket, endpoint: EndpointInfo): Established {
        val session = try {
            handshakeClient.handshake(socket, endpoint.deviceId, endpoint.fingerprint)
        } catch (e: ConnectionException) {
            closeQuietly(socket)
            throw e
        }
        // The address that actually answered goes first next time.
        val connected = socket.inetAddress?.hostAddress
        val addresses = listOfNotNull(connected) + endpoint.addresses.filter { it != connected }
        return Established(socket, session, addresses, endpoint.port)
    }

    /** This phone's user confirmed that both devices show the same code. */
    fun confirmPairing() {
        val pairing = _state.value as? TransferState.Pairing ?: return
        if (pairing.confirmedLocally) return
        if (!_state.compareAndSet(pairing, pairing.copy(confirmedLocally = true))) return
        sendPairingConfirm(accepted = true)
    }

    /** This phone's user declined pairing. The Mac answers `pairing_result{false}` and closes. */
    fun declinePairing() {
        if (_state.value !is TransferState.Pairing) return
        _state.value = TransferState.Idle
        sendPairingConfirm(accepted = false)
    }

    /** Cancels whatever is in progress, telling the receiver when a transfer was announced. */
    fun cancel() {
        val current = _state.value
        if (current is TransferState.Idle || current.isFinal()) return
        _state.value = TransferState.Cancelled(current.peerName(), byPeer = false)
        job?.cancel()
        val activeChannel = channel ?: return
        val transferId = activeTransferId
        scope.launch(Dispatchers.IO) {
            try {
                if (transferId != null) activeChannel.send(TransferMessages.cancel(transferId, "user_cancelled"))
                activeChannel.send(Message(MessageType.CLOSE))
                Log.i(TAG, "Sent cancel to ${activeChannel.remoteDescription}")
            } catch (e: ConnectionException) {
                Log.i(TAG, "Peer already gone while cancelling: ${e.message}")
            }
            activeChannel.close()
        }
        // A send blocked on a stalled connection holds the channel; closing the socket releases it.
        scope.launch {
            delay(CANCEL_GRACE_MS)
            activeChannel.close()
        }
    }

    /**
     * Adds [source]'s files to the request awaiting the receiver's decision, if it goes to
     * [deviceId]: the receiver's prompt grows instead of a second one following. False if there
     * is no such request, it was already decided, or the files can't be read — then [source]
     * is sent on its own later.
     */
    suspend fun append(deviceId: String, source: TransferSource): Boolean = withContext(Dispatchers.IO) {
        val open = synchronized(requestLock) { pendingRequest?.let { !it.decided && it.deviceId == deviceId } == true }
        if (!open) return@withContext false
        val files = try {
            source.files()
        } catch (e: IOException) {
            Log.w(TAG, "Can't add ${source.description}: ${e.message}")
            return@withContext false
        } catch (e: SecurityException) {
            Log.w(TAG, "Can't add ${source.description}: ${e.message}")
            return@withContext false
        }
        if (files.isEmpty()) return@withContext false
        val activeChannel = channel ?: return@withContext false
        synchronized(requestLock) {
            val request = pendingRequest
            if (request == null || request.decided || request.deviceId != deviceId || request.files.size + files.size > MAX_FILES) {
                return@withContext false
            }
            val first = request.files.size
            val total = request.files.sumOf { it.size } + files.sumOf { it.size }
            val infos = files.mapIndexed { index, file -> TransferMessages.FileInfo(first + index, file.name, file.mimeType, file.size, file.lastModified) }
            try {
                activeChannel.send(TransferMessages.add(request.transferId, infos, total))
            } catch (e: ConnectionException) {
                Log.w(TAG, "Could not send transfer_add: ${e.message}")
                return@withContext false
            }
            request.files += files
            request.appended += source to files.size
            _state.update { state ->
                if (state is TransferState.AwaitingApproval) state.copy(summary = TransferSummary(request.files.size, total, request.files.first().name)) else state
            }
            Log.i(TAG, "transfer_add sent: ${files.size} more file(s), now ${request.files.size}")
        }
        true
    }

    /** Acknowledges a final state (completed, failed, cancelled) and returns to Idle. */
    fun dismiss() {
        _state.update { if (it.isFinal()) TransferState.Idle else it }
    }

    // region Receive (Mac → phone)

    private suspend fun runReceive(channel: SecureChannel, peer: PeerIdentity, options: ReceiveOptions) {
        channel.send(Message(MessageType.RECEIVE_READY))
        Log.i(TAG, "receive_ready sent to ${peer.deviceId}")
        val received = mutableListOf<ReceivedFile>()
        val texts = mutableListOf<String>()
        var next = readAsync(channel, DELIVERY_WAIT_MS, "delivery")
        while (true) {
            val message = next.await()
            when (message.type) {
                MessageType.NOTHING_PENDING -> break
                MessageType.TRANSFER_REQUEST -> {
                    val request = decoding { IncomingRequest.parse(message) }
                    next = receiveTransfer(channel, peer, request, options, received)
                }
                // Text or a link for the clipboard: taken without asking, like on the Mac (messages.md `text`).
                MessageType.TEXT -> {
                    val transferId = decoding { message.bytes("transferId", 16) }
                    val text = decoding { message.text("text") }
                    if (text.isEmpty() || text.toByteArray(Charsets.UTF_8).size > ProtocolConstants.MAX_TEXT_SIZE) {
                        throw ConnectionException.ProtocolViolation("text of ${text.length} characters")
                    }
                    texts += text
                    Log.i(TAG, "Text from ${peer.deviceId}: ${text.length} characters")
                    channel.send(TransferMessages.textResult(transferId, copied = true))
                    next = readAsync(channel, DELIVERY_WAIT_MS, "delivery")
                }
                MessageType.CANCEL -> throw ConnectionException.CancelledByPeer()
                else -> throw ConnectionException.ProtocolViolation("unexpected ${message.type} while waiting for a delivery")
            }
        }
        Log.i(TAG, "Delivery from ${peer.deviceId} done: ${received.size} file(s) saved")
        advance(
            if (received.isEmpty() && texts.isEmpty()) {
                TransferState.NothingReceived(peer.name)
            } else {
                TransferState.Received(peer.name, received, texts)
            },
        )
    }

    /**
     * A blocking read that isn't a child of the session's coroutine: it can't be cancelled, and
     * the session closes the socket (ending the read) only after its own scope has finished.
     */
    private fun readAsync(channel: SecureChannel, timeoutMs: Long, stage: String): Deferred<Message> =
        scope.async(Dispatchers.IO) { channel.receive(timeoutMs, stage) }

    /** One `transfer_request`. Returns the read in flight for the Mac's next message. */
    private suspend fun receiveTransfer(
        channel: SecureChannel,
        peer: PeerIdentity,
        request: IncomingRequest,
        options: ReceiveOptions,
        received: MutableList<ReceivedFile>,
    ): Deferred<Message> {
        activeTransferId = request.transferId
        val summary = TransferSummary(request.files.size, request.totalSize, request.files.first().name)
        Log.i(TAG, "Delivery offered: ${request.files.size} file(s), ${request.totalSize} bytes")
        if (freeSpace() < request.totalSize + RECEIVE_SPACE_MARGIN) {
            channel.send(TransferMessages.reject(request.transferId, "insufficient_storage"))
            throw ConnectionException.NotEnoughSpace(request.totalSize)
        }

        // The Mac may cancel while this phone's user decides, so its next message is read meanwhile.
        val peerMessage = readAsync(channel, DECISION_TIMEOUT_MS + REPLY_TIMEOUT_MS, "decision")
        val decision = CompletableDeferred<Boolean>().also { pendingDecision = it }
        if (options.autoAccept) decision.complete(true) else advance(TransferState.AwaitingLocalDecision(peer.name, summary))
        val accepted = withTimeoutOrNull(DECISION_TIMEOUT_MS) {
            select<Boolean?> {
                decision.onAwait { it }
                peerMessage.onAwait { null }
            }
        }
        pendingDecision = null
        when {
            accepted == null && peerMessage.isCompleted -> {
                val message = peerMessage.await()
                if (message.type == MessageType.CANCEL) throw ConnectionException.CancelledByPeer()
                throw ConnectionException.ProtocolViolation("unexpected ${message.type} before the decision")
            }
            accepted != true -> {
                Log.i(TAG, if (accepted == null) "Delivery not answered in time" else "Delivery declined")
                channel.send(TransferMessages.reject(request.transferId, if (accepted == null) "timeout" else "declined"))
                activeTransferId = null
                return peerMessage
            }
        }

        channel.send(TransferMessages.accept(request.transferId, request.files.size))
        Log.i(TAG, "Delivery accepted${if (options.autoAccept) " automatically" else ""}")
        val progress = ReceiveProgress(peer.name, request)
        progress.emit(force = true)
        var buffered: Deferred<Message>? = peerMessage
        suspend fun next(stage: String): Message {
            val inFlight = buffered
            buffered = null
            val message = inFlight?.await() ?: channel.receive(REPLY_TIMEOUT_MS, stage)
            if (message.type == MessageType.CANCEL) throw ConnectionException.CancelledByPeer()
            return message
        }

        for (file in request.files) {
            val begin = next("file_begin")
            decoding {
                begin.expect(MessageType.FILE_BEGIN)
                if (begin.uint("fileId").toInt() != file.fileId || begin.uint("offset") != 0L) {
                    throw ConnectionException.ProtocolViolation("file_begin out of order")
                }
            }
            val writer = try {
                DownloadWriter.create(contentResolver, file)
            } catch (e: IOException) {
                reportFailure(channel, request.transferId, file.fileId, ErrorCode.WRITE_FAILED)
                throw ConnectionException.SaveFailed(file.name, e)
            }
            var published = false
            val fileStarted = SystemClock.elapsedRealtime()
            var networkNs = 0L
            var writeNs = 0L
            val cost = channel.receiveCost
            val costAtStart = Triple(cost.readNs, cost.decryptNs, cost.parseNs)
            try {
                val digest = MessageDigest.getInstance("SHA-256")
                var written = 0L
                while (written < file.size) {
                    val waitStart = System.nanoTime()
                    val chunk = next("file data")
                    networkNs += System.nanoTime() - waitStart
                    val data = decoding {
                        chunk.expect(MessageType.FILE_CHUNK)
                        if (chunk.uint("fileId").toInt() != file.fileId || chunk.uint("offset") != written) {
                            throw ConnectionException.ProtocolViolation("file_chunk out of order")
                        }
                        chunk.bytes("data")
                    }
                    if (data.isEmpty() || written + data.size > file.size) throw ConnectionException.ProtocolViolation("file_chunk exceeds the announced size")
                    val writeStart = System.nanoTime()
                    try {
                        writer.write(data, 0, data.size)
                        writeNs += System.nanoTime() - writeStart
                    } catch (e: IOException) {
                        reportFailure(channel, request.transferId, file.fileId, ErrorCode.WRITE_FAILED)
                        throw ConnectionException.SaveFailed(file.name, e)
                    }
                    digest.update(data)
                    written += data.size
                    progress.add(file, data.size.toLong())
                }
                val end = next("file_end")
                val expected = decoding {
                    end.expect(MessageType.FILE_END)
                    if (end.uint("fileId").toInt() != file.fileId) throw ConnectionException.ProtocolViolation("file_end out of order")
                    end.bytes("sha256")
                }
                if (!MessageDigest.isEqual(digest.digest(), expected)) {
                    reportFailure(channel, request.transferId, file.fileId, ErrorCode.CHECKSUM_MISMATCH)
                    throw ConnectionException.ReceiverFailed(ErrorCode.CHECKSUM_MISMATCH, file.name)
                }
                try {
                    writer.publish()
                } catch (e: IOException) {
                    reportFailure(channel, request.transferId, file.fileId, ErrorCode.WRITE_FAILED)
                    throw ConnectionException.SaveFailed(file.name, e)
                }
                published = true
                received += ReceivedFile(writer.uri, writer.displayName(file.name), writer.mimeType, file.size)
                channel.send(TransferMessages.fileResult(request.transferId, file.fileId, ok = true))
                val elapsedMs = SystemClock.elapsedRealtime() - fileStarted
                Log.i(
                    TAG,
                    "Saved file ${file.fileId} (${file.size} bytes, SHA-256 verified) at ${rate(file.size, elapsedMs)}: " +
                        "receiving ${networkNs / 1_000_000} ms (network ${(cost.readNs - costAtStart.first) / 1_000_000}, " +
                        "decrypting ${(cost.decryptNs - costAtStart.second) / 1_000_000}, parsing ${(cost.parseNs - costAtStart.third) / 1_000_000}), " +
                        "writing ${writeNs / 1_000_000} ms of $elapsedMs ms",
                )
            } finally {
                if (!published) writer.discard()
            }
        }
        val complete = next("transfer_complete")
        decoding { complete.expect(MessageType.TRANSFER_COMPLETE) }
        channel.send(TransferMessages.transferResult(request.transferId, completed = true))
        activeTransferId = null
        return readAsync(channel, DELIVERY_WAIT_MS, "delivery")
    }

    private fun reportFailure(channel: SecureChannel, transferId: ByteArray, fileId: Int, code: String) {
        sendQuietly(channel, TransferMessages.fileResult(transferId, fileId, ok = false, code = code))
        sendQuietly(channel, TransferMessages.transferResult(transferId, completed = false, code = code))
    }

    /** Progress of a delivery, emitted at most every [PROGRESS_INTERVAL_MS]. */
    private inner class ReceiveProgress(private val peerName: String, private val request: IncomingRequest) {
        private var bytes = 0L
        private var lastEmitAt = 0L
        private var current = request.files.first()
        private val samples = ArrayDeque<Pair<Long, Long>>()

        fun add(file: IncomingFile, count: Long) {
            current = file
            bytes += count
            emit(force = false)
        }

        fun emit(force: Boolean) {
            val now = SystemClock.elapsedRealtime()
            if (!force && now - lastEmitAt < PROGRESS_INTERVAL_MS) return
            lastEmitAt = now
            samples.addLast(now to bytes)
            while (samples.size > 1 && now - samples.first().first > AVERAGE_WINDOW_MS) samples.removeFirst()
            val speed = samples.rate(now, bytes, SPEED_WINDOW_MS)
            val average = samples.rate(now, bytes, AVERAGE_WINDOW_MS)
            advance(TransferState.Receiving(peerName, TransferProgress(bytes, request.totalSize, current.name, current.fileId, request.files.size, speed, average, request.files.map { it.size })))
        }
    }

    // endregion

    // region Transfer

    /** Text → the receiver's clipboard: one message, one answer, no prompt on the Mac. */
    private fun runText(channel: SecureChannel, peerName: String, text: String) {
        val transferId = randomBytes(16)
        activeTransferId = transferId
        channel.send(TransferMessages.text(transferId, text))
        val answer = channel.receive(REPLY_TIMEOUT_MS, "text_result")
        when (answer.type) {
            MessageType.TEXT_RESULT -> when (val status = decoding { answer.text("status") }) {
                "copied" -> {
                    Log.i(TAG, "Text copied on the receiver (${text.length} chars)")
                    advance(TransferState.TextCopied(peerName))
                }
                else -> throw ConnectionException.TransferRejected(status)
            }
            else -> throw ConnectionException.ProtocolViolation("unexpected ${answer.type} instead of text_result")
        }
    }

    private suspend fun runTransfer(channel: SecureChannel, deviceId: String, peerName: String, source: TransferSource) {
        val files = try {
            source.files()
        } catch (e: IOException) {
            throw ConnectionException.SourceUnavailable(source.description, e)
        } catch (e: SecurityException) {
            throw ConnectionException.SourceUnavailable(source.description, e)
        }
        if (files.isEmpty()) throw ConnectionException.SourceUnavailable(source.description, null)
        // Resolving the files froze a batch: these are the parts the request announces.
        val parts = source.parts
        val transferId = randomBytes(16)
        activeTransferId = transferId
        synchronized(requestLock) { pendingRequest = PendingRequest(transferId, deviceId, files.toMutableList()) }

        channel.send(
            TransferMessages.request(
                transferId,
                files.mapIndexed { index, file -> TransferMessages.FileInfo(index, file.name, file.mimeType, file.size, file.lastModified) },
            ),
        )
        if (!advance(TransferState.AwaitingApproval(peerName, TransferSummary(files.size, files.sumOf { it.size }, files.first().name)))) return
        Log.i(TAG, "transfer_request sent: ${files.size} file(s), ${files.sumOf { it.size }} bytes")

        val answer = channel.receive(APPROVAL_TIMEOUT_MS, "approval")
        val (announced, appended) = synchronized(requestLock) {
            val request = checkNotNull(pendingRequest)
            request.decided = true
            request.files.toList() to request.appended.toList()
        }
        // The decision covers the first `fileCount` files: the request plus the adds the receiver
        // read in time. Absent: the original request only.
        val fileCount = decoding { (answer.body["fileCount"] as? CborValue.UInt)?.value }
            ?.coerceIn(files.size.toLong(), announced.size.toLong())?.toInt()
            ?: if (answer.type == MessageType.CANCEL) announced.size else files.size
        var covered = files.size
        val included = parts.toMutableList()
        for ((part, count) in appended) {
            if (covered + count > fileCount) break
            included += part
            covered += count
        }
        decidedParts = included
        if (covered < announced.size) Log.i(TAG, "${announced.size - covered} added file(s) came too late; sent separately")
        val accepted = announced.take(covered)
        val summary = TransferSummary(accepted.size, accepted.sumOf { it.size }, accepted.first().name)
        when (answer.type) {
            MessageType.TRANSFER_ACCEPT -> Log.i(TAG, "Transfer accepted")
            MessageType.TRANSFER_REJECT -> throw ConnectionException.TransferRejected(decoding { answer.text("reason") })
            MessageType.CANCEL -> throw ConnectionException.CancelledByPeer()
            else -> throw ConnectionException.ProtocolViolation("unexpected ${answer.type} instead of transfer_accept")
        }

        val started = SystemClock.elapsedRealtime()
        // From here the receiver may speak at any time (cancel, early failure), so a reader runs
        // alongside the sender. Its blocking read has no timeout (the watchdog covers stalls) and
        // ends when the socket closes, so it is not a child of the scope below, which would wait for it.
        val inbox = Channel<Message>(capacity = 16)
        scope.launch(Dispatchers.IO) {
            try {
                while (true) inbox.send(channel.receive(timeoutMs = 0, stage = "receiver"))
            } catch (e: ConnectionException) {
                inbox.close(e)
            }
        }
        coroutineScope {
            val streamer = Streamer(channel, inbox, transferId, peerName, accepted)
            val watchdog = launch {
                while (isActive) {
                    delay(WATCHDOG_INTERVAL_MS)
                    if (SystemClock.elapsedRealtime() - streamer.lastProgressAt > STALL_TIMEOUT_MS) {
                        Log.w(TAG, "No progress for ${STALL_TIMEOUT_MS / 1000} s; closing the connection")
                        streamer.stalled = true
                        channel.close()
                    }
                }
            }
            try {
                streamer.run()
            } catch (e: ConnectionException.ConnectionLost) {
                if (streamer.stalled) throw ConnectionException.Timeout("transfer progress")
                // The receiver often explains before closing (e.g. trust revoked); the write may
                // fail before the reader has parsed that message, so give the reader a moment.
                throw peerExplanation(inbox) ?: e
            } finally {
                watchdog.cancel()
            }
        }
        val durationMs = SystemClock.elapsedRealtime() - started
        Log.i(TAG, "Transfer complete: ${summary.totalBytes} bytes in $durationMs ms (${rate(summary.totalBytes, durationMs)})")
        advance(TransferState.Completed(peerName, summary, durationMs))
    }

    /** The receiver's own reason for ending the transfer, if it sent one just before closing. */
    private suspend fun peerExplanation(inbox: Channel<Message>): ConnectionException? {
        val result = withTimeoutOrNull(PEER_EXPLANATION_WAIT_MS) { inbox.receiveCatching() } ?: return null
        val cause = result.exceptionOrNull()
        if (cause is ConnectionException.PeerError || cause is ConnectionException.CancelledByPeer) return cause as ConnectionException
        val message = result.getOrNull() ?: return null
        return when (message.type) {
            MessageType.CANCEL -> ConnectionException.CancelledByPeer()
            MessageType.FILE_RESULT, MessageType.TRANSFER_RESULT -> ConnectionException.ReceiverFailed(
                (message.body["code"] as? CborValue.Text)?.value ?: "unknown",
                null,
            )
            else -> null
        }
    }

    /** Streams all files. One instance per transfer; not thread-safe except for the watchdog fields. */
    private inner class Streamer(
        private val channel: SecureChannel,
        private val inbox: Channel<Message>,
        private val transferId: ByteArray,
        private val peerName: String,
        private val files: List<SourceFile>,
    ) {
        @Volatile var lastProgressAt = SystemClock.elapsedRealtime()

        @Volatile var stalled = false

        private val totalBytes = files.sumOf { it.size }
        private val fileSizes = files.map { it.size }
        private var bytesSent = 0L
        private var lastEmitAt = 0L
        private val samples = ArrayDeque<Pair<Long, Long>>()

        suspend fun run() {
            val buffer = ByteArray(ProtocolConstants.CHUNK_SIZE)
            files.forEachIndexed { index, file ->
                val digest = MessageDigest.getInstance("SHA-256")
                channel.send(TransferMessages.fileBegin(transferId, index))
                openSource(file).use { input ->
                    var offset = 0L
                    while (offset < file.size) {
                        coroutineContext.ensureActive()
                        checkInbox(file)
                        val wanted = minOf(buffer.size.toLong(), file.size - offset).toInt()
                        val read = readFully(input, buffer, wanted, file)
                        digest.update(buffer, 0, read)
                        val data = if (read == buffer.size) buffer else buffer.copyOf(read)
                        channel.send(TransferMessages.fileChunk(transferId, index, offset, data))
                        offset += read
                        bytesSent += read
                        lastProgressAt = SystemClock.elapsedRealtime()
                        emitProgress(file, index, force = false)
                    }
                }
                channel.send(TransferMessages.fileEnd(transferId, index, digest.digest()))
                emitProgress(file, index, force = true)
                if (index == files.lastIndex) {
                    advance(TransferState.Verifying(peerName, progress(file, index)))
                }
                val result = awaitReply(MessageType.FILE_RESULT, file)
                if (!decoding { result.bool("ok") }) {
                    throw ConnectionException.ReceiverFailed(errorCode(result), file.name)
                }
                Log.i(TAG, "File $index verified by receiver (${file.size} bytes)")
            }
            channel.send(TransferMessages.transferComplete(transferId))
            val result = awaitReply(MessageType.TRANSFER_RESULT, files.last())
            if (decoding { result.text("status") } != "completed") {
                throw ConnectionException.ReceiverFailed(errorCode(result), null)
            }
        }

        private fun openSource(file: SourceFile): InputStream = try {
            file.open()
        } catch (e: IOException) {
            throw ConnectionException.SourceUnavailable(file.name, e)
        } catch (e: SecurityException) {
            throw ConnectionException.SourceUnavailable(file.name, e)
        }

        /** Reads exactly [length] bytes; a source shorter than announced is unavailable. */
        private fun readFully(input: InputStream, buffer: ByteArray, length: Int, file: SourceFile): Int {
            var filled = 0
            try {
                while (filled < length) {
                    val n = input.read(buffer, filled, length - filled)
                    if (n < 0) throw ConnectionException.SourceUnavailable(file.name, IOException("file ended early"))
                    filled += n
                }
            } catch (e: IOException) {
                throw ConnectionException.SourceUnavailable(file.name, e)
            } catch (e: SecurityException) {
                throw ConnectionException.SourceUnavailable(file.name, e)
            }
            return filled
        }

        /** Between chunks, the receiver may only have cancelled or reported a failure. */
        private fun checkInbox(file: SourceFile) {
            val result = inbox.tryReceive()
            result.exceptionOrNull()?.let { throw it }
            val message = result.getOrNull() ?: return
            handleUnexpected(message, file)
        }

        private suspend fun awaitReply(type: String, file: SourceFile): Message {
            lastProgressAt = SystemClock.elapsedRealtime()
            // A closed inbox rethrows the reader's ConnectionException here.
            val message = try {
                withTimeout(REPLY_TIMEOUT_MS) { inbox.receive() }
            } catch (e: TimeoutCancellationException) {
                throw ConnectionException.Timeout(type)
            }
            if (message.type == type) return message
            handleUnexpected(message, file)
            throw ConnectionException.ProtocolViolation("unexpected ${message.type}")
        }

        private fun handleUnexpected(message: Message, file: SourceFile) {
            when (message.type) {
                MessageType.CANCEL -> throw ConnectionException.CancelledByPeer()
                MessageType.FILE_RESULT, MessageType.TRANSFER_RESULT ->
                    throw ConnectionException.ReceiverFailed(errorCode(message), file.name)
                else -> throw ConnectionException.ProtocolViolation("unexpected ${message.type} during transfer")
            }
        }

        private fun errorCode(message: Message): String =
            (message.body["code"] as? CborValue.Text)?.value ?: "unknown"

        private fun emitProgress(file: SourceFile, index: Int, force: Boolean) {
            val now = SystemClock.elapsedRealtime()
            if (!force && now - lastEmitAt < PROGRESS_INTERVAL_MS) return
            lastEmitAt = now
            samples.addLast(now to bytesSent)
            while (samples.size > 1 && now - samples.first().first > AVERAGE_WINDOW_MS) samples.removeFirst()
            advance(TransferState.Transferring(peerName, progress(file, index)))
        }

        private fun progress(file: SourceFile, index: Int): TransferProgress {
            val now = SystemClock.elapsedRealtime()
            val speed = samples.rate(now, bytesSent, SPEED_WINDOW_MS)
            val average = samples.rate(now, bytesSent, AVERAGE_WINDOW_MS)
            return TransferProgress(bytesSent, totalBytes, file.name, index, files.size, speed, average, fileSizes)
        }
    }

    // endregion

    // region Pairing

    private fun sendPairingConfirm(accepted: Boolean) {
        val activeChannel = channel ?: return
        scope.launch(Dispatchers.IO) {
            try {
                activeChannel.send(Message(MessageType.PAIRING_CONFIRM, mapOf("accepted" to CborValue.Bool(accepted))))
                Log.i(TAG, "Sent pairing_confirm(accepted=$accepted)")
            } catch (e: ConnectionException) {
                // The session job sees the same failure on its read and reports it.
                Log.w(TAG, "Could not send pairing_confirm: ${e.message}")
            }
        }
    }

    /**
     * Waits for `pairing_result`. The Mac may answer `false` before this phone's user decides,
     * so this read runs while the code is on screen. Persists the peer on success.
     */
    private fun awaitPairingResult(channel: SecureChannel, peer: PeerIdentity) {
        val message = channel.receive(PAIRING_TIMEOUT_MS, "pairing confirmation")
        val accepted = decoding { message.expect(MessageType.PAIRING_RESULT).bool("accepted") }
        val presenceKey = message.presenceKey()
        if (!accepted) throw ConnectionException.PairingRejected(byPeer = _state.value is TransferState.Pairing)
        val confirmed = (_state.value as? TransferState.Pairing)?.confirmedLocally == true
        if (!confirmed) throw ConnectionException.ProtocolViolation("pairing_result(true) before local confirmation")
        try {
            trustStore.trust(peer.deviceId, peer.name, peer.identityKey, peer.fingerprint, presenceKey, peer.capabilities)
        } catch (e: IOException) {
            throw ConnectionException.StorageFailed(e)
        }
        Log.i(TAG, "Paired with ${peer.deviceId}")
    }

    // endregion

    /** Moves to [next] unless the user cancelled meanwhile. Returns false if the transfer should stop. */
    private fun advance(next: TransferState): Boolean {
        var applied = false
        _state.update { current ->
            if (current is TransferState.Idle || current.isFinal()) {
                current
            } else {
                applied = true
                next
            }
        }
        return applied
    }

    private fun sendQuietly(channel: SecureChannel, message: Message) {
        try {
            channel.send(message)
        } catch (e: ConnectionException) {
            Log.i(TAG, "Could not send ${message.type}: ${e.message}")
        }
    }

    private fun closeQuietly(socket: Socket?) {
        try {
            socket?.close()
        } catch (e: IOException) {
            Log.w(TAG, "Error closing socket: ${e.message}")
        }
    }

    private fun rate(bytes: Long, ms: Long) = if (ms > 0) "%.1f MB/s".format(bytes / 1000.0 / ms) else "-"

    private companion object {
        const val TAG = "LD/transfer"

        /** Longer than the Mac's USER_DECISION_TIMEOUT so its own timeout answer arrives first. */
        const val PAIRING_TIMEOUT_MS = 135_000L
        const val APPROVAL_TIMEOUT_MS = 135_000L
        const val REPLY_TIMEOUT_MS = 60_000L
        const val STALL_TIMEOUT_MS = 30_000L
        const val WATCHDOG_INTERVAL_MS = 5_000L
        const val PROGRESS_INTERVAL_MS = 100L
        const val SPEED_WINDOW_MS = 2_000L
        const val AVERAGE_WINDOW_MS = 10_000L
        const val CANCEL_GRACE_MS = 2_000L
        const val PEER_EXPLANATION_WAIT_MS = 500L

        /** The Mac answers `receive_ready` at once; after a delivery it sends the next one or `nothing_pending`. */
        const val DELIVERY_WAIT_MS = 30_000L

        /** Shorter than the Mac's acceptance timeout (180 s), so this phone's `timeout` answer arrives first. */
        const val DECISION_TIMEOUT_MS = 170_000L

        /** Downloads keeps this much free beyond what the Mac sends. */
        const val RECEIVE_SPACE_MARGIN = 200L * 1024 * 1024

        /** protocol/messages.md: a transfer has at most 1000 files. */
        const val MAX_FILES = 1000
    }
}

fun TransferState.isFinal(): Boolean =
    this is TransferState.Completed || this is TransferState.Failed || this is TransferState.Cancelled ||
        this is TransferState.Paired || this is TransferState.TextCopied ||
        this is TransferState.Received || this is TransferState.NothingReceived

fun TransferState.peerName(): String = when (this) {
    TransferState.Idle -> ""
    is TransferState.Connecting -> peerName
    is TransferState.Pairing -> peer.name
    is TransferState.Preparing -> peerName
    is TransferState.AwaitingApproval -> peerName
    is TransferState.Transferring -> peerName
    is TransferState.Verifying -> peerName
    is TransferState.Completed -> peerName
    is TransferState.TextCopied -> peerName
    is TransferState.AwaitingLocalDecision -> peerName
    is TransferState.Receiving -> peerName
    is TransferState.Received -> peerName
    is TransferState.NothingReceived -> peerName
    is TransferState.Paired -> peerName
    is TransferState.Failed -> peerName
    is TransferState.Cancelled -> peerName
}

/** Bytes per second since the oldest (time, bytes) sample at most [windowMs] old; 0 until there are two. */
private fun ArrayDeque<Pair<Long, Long>>.rate(now: Long, bytes: Long, windowMs: Long): Long {
    val (time, from) = firstOrNull { now - it.first <= windowMs } ?: return 0
    return if (now > time) (bytes - from) * 1000 / (now - time) else 0
}
