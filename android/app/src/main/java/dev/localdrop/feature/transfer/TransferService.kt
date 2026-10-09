package dev.localdrop.feature.transfer

import android.Manifest
import android.app.DownloadManager
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.text.format.Formatter
import android.util.Log
import android.util.Size
import android.widget.Toast
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import dev.localdrop.R
import dev.localdrop.app.LocalDropApplication
import dev.localdrop.app.MainActivity
import dev.localdrop.core.device.TrustedDevice
import dev.localdrop.core.history.HistoryEntry
import dev.localdrop.core.queue.AvailabilityTrigger
import dev.localdrop.core.queue.QueuedTransfer
import dev.localdrop.core.queue.SpoolSpaceException
import dev.localdrop.core.transfer.BatchSource
import dev.localdrop.core.transfer.ContentUriSource
import dev.localdrop.core.transfer.SendTarget
import dev.localdrop.core.transfer.TestDataSource
import dev.localdrop.core.transfer.TransferProgress
import dev.localdrop.core.transfer.TransferSource
import dev.localdrop.core.transfer.TransferState
import dev.localdrop.core.transfer.isFinal
import dev.localdrop.core.transport.ConnectionException
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Timer retries after a send found its device unavailable; the delay doubles up to the maximum.
 * Each network attempt wakes a sleeping Mac for a moment (macOS wakes for incoming connections),
 * so while Bluetooth watches for the Mac — which advertises again as soon as it really wakes —
 * the timer is only a rare safety net. Without Bluetooth it is the main way to notice the Mac.
 */
private const val FIRST_RETRY_MS = 30_000L
private const val MAX_RETRY_DELAY_MS = 5 * 60_000L
private const val FIRST_RETRY_WATCHED_MS = 5 * 60_000L
private const val MAX_RETRY_WATCHED_MS = 15 * 60_000L

/** Triggers (Mac appeared, network changed) never retry a device more often than this. */
private const val MIN_ATTEMPT_GAP_MS = 10_000L

/** Bluetooth watching is low-latency this long after a send starts waiting, then balanced. */
private const val CLOSE_WATCH_MS = 5 * 60_000L

/** After this long without reaching the device, the send is parked: kept on disk, the service stops. */
private const val MAX_WAIT_MS = 60 * 60_000L

/**
 * One requested send. Once it has to wait, it is copied into the spool ([queued]) and sent from
 * that copy, so it outlives the share's URI grant and the process.
 */
private class OutgoingTransfer(
    val id: String,
    val deviceId: String,
    var source: TransferSource,
    /** Diagnostics test data is never kept for later. */
    val canWait: Boolean,
    var queued: QueuedTransfer? = null,
) {
    /** elapsedRealtime when it started waiting for its device; null while it is ready to go. */
    var waitingSinceMs: Long? = null
    var retryAtMs = 0L
    var retryDelayMs = FIRST_RETRY_MS
    var lastAttemptMs = Long.MIN_VALUE / 2

    /** The copy failed (no space, source unreadable): it waits only while the service runs. */
    var spoolFailed = false

    fun isDue(nowMs: Long) = waitingSinceMs == null || retryAtMs <= nowMs

    /** Files go together with other shares to the same device; clipboard text and test data go alone. */
    val joinsBatches: Boolean get() = canWait && source.clipboardText == null
}

/** What the manager is sending: one share, or several to the same device as one transfer. */
private class Batch(val deviceId: String, val source: TransferSource, val items: MutableList<OutgoingTransfer>)

/**
 * Foreground service that owns outgoing transfers started from the Sharesheet (or Diagnostics).
 * It runs only while there is work, and shows progress, pairing and results as notifications,
 * so the user never has to open LocalDrop.
 *
 * Shared `content://` URIs arrive with their read grant attached to the service intent, so
 * access lasts while the service runs, after the share activity has finished.
 *
 * Send later (Milestone 8): when the Mac is asleep, away or on another network, a send waits
 * instead of failing. It is copied into [dev.localdrop.core.queue.OutgoingStore] and retried when
 * the Mac shows up over Bluetooth, when the phone's network changes, and on a backoff timer. After
 * [MAX_WAIT_MS] it is parked: kept on disk with a "Try again" notification, and retried whenever
 * LocalDrop is opened or used to send again. Android doesn't let a backgrounded app restart a
 * foreground service by itself, so a parked send needs one of those user actions.
 */
class TransferService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** Every send this service owns, oldest first, including the running one. */
    private val items = mutableListOf<OutgoingTransfer>()
    private var current: Batch? = null
    private var currentDeviceName = ""

    /** Macs to take files from (Mac → phone, protocol.md §2.8), and the one being received from. */
    private val receiveQueue = ArrayDeque<String>()
    private var receiving: TrustedDevice? = null
    private var spoolJob: Job? = null
    private var watchJob: Job? = null
    private var retryJob: Job? = null
    private var inForeground = false
    private var resultNotificationId = RESULT_NOTIFICATION_BASE
    private var lastProgressNotificationMs = 0L
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private val container get() = (application as LocalDropApplication).container
    private val manager get() = container.transferManager
    private val outgoingStore get() = container.outgoingStore
    private val history get() = container.historyStore
    private val notifications get() = NotificationManagerCompat.from(this)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannels(this)
        scope.launch { manager.state.collect(::onState) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Every start must promote to foreground within seconds, whatever the action.
        startForegroundIfNeeded()
        when (intent?.action) {
            ACTION_SEND -> {
                // Sending again means the user expects the Mac to be around: kept sends go too.
                restoreQueued()
                enqueue(intent)
            }
            ACTION_RESUME -> {
                notifications.cancel(PARKED_NOTIFICATION_ID)
                restoreQueued()
                retryAllNow()
            }
            ACTION_DISCARD -> discardParked()
            ACTION_RECEIVE -> enqueueReceive(intent.getStringExtra(EXTRA_DEVICE_ID))
            ACTION_ACCEPT_INCOMING -> manager.acceptIncoming()
            ACTION_DECLINE_INCOMING -> manager.declineIncoming()
            ACTION_CANCEL -> cancelAll()
            ACTION_CONFIRM_PAIRING -> manager.confirmPairing()
            ACTION_DECLINE_PAIRING -> manager.declinePairing()
        }
        pump()
        stopIfIdle()
        return START_NOT_STICKY
    }

    /** Android 15+: the daily `dataSync` budget ran out. Keep what waits and stop. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "Foreground time limit reached; parking ${items.size} send(s)")
        park(items.filter { !isCurrent(it) })
        manager.cancel()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        inForeground = false
        stopSelf()
    }

    override fun onDestroy() {
        releaseLocks()
        scope.cancel()
        super.onDestroy()
    }

    private fun enqueue(intent: Intent) {
        val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID) ?: return
        val testSize = intent.getLongExtra(EXTRA_TEST_SIZE, -1)
        val source = if (testSize > 0) {
            TestDataSource(testSize)
        } else {
            val clip = intent.clipData
            val uris = if (clip == null) emptyList() else List(clip.itemCount) { clip.getItemAt(it).uri }.filterNotNull()
            ContentUriSource(contentResolver, uris, intent.getStringExtra(EXTRA_TEXT))
        }
        val item = OutgoingTransfer(UUID.randomUUID().toString(), deviceId, source, canWait = testSize <= 0)
        items += item
        // A new send to a device with waiting ones: try them all now, together.
        items.filter { it.deviceId == deviceId && it.waitingSinceMs != null }.forEach { it.retryAtMs = 0 }
        Log.i(TAG, "Queued transfer to $deviceId (${source.description}); ${items.size} in queue")
        joinCurrent(item)
    }

    private fun isCurrent(item: OutgoingTransfer) = current?.items?.contains(item) == true

    /**
     * A share for the device being sent to joins that send instead of queueing behind it: into
     * the batch while its request isn't built yet, or into the request on the receiver's screen.
     */
    private fun joinCurrent(item: OutgoingTransfer) {
        val batch = current ?: return
        val source = batch.source as? BatchSource ?: return
        if (batch.deviceId != item.deviceId || !item.joinsBatches) return
        // The outcome applies only if the manager reports it included (see handleOutcome).
        batch.items += item
        item.lastAttemptMs = SystemClock.elapsedRealtime()
        if (source.tryAdd(item.source)) {
            Log.i(TAG, "${item.id} joins the send in progress")
            return
        }
        scope.launch {
            val added = manager.append(item.deviceId, item.source)
            Log.i(TAG, if (added) "${item.id} added to the request awaiting a decision" else "${item.id} goes after the current send")
        }
    }

    /** Adds kept sends from disk that this service doesn't hold yet (parked, or from before a restart). */
    private fun restoreQueued() {
        outgoingStore.load()
        for (queued in outgoingStore.items.value) {
            if (items.any { it.id == queued.id }) continue
            items += OutgoingTransfer(queued.id, queued.deviceId, outgoingStore.source(queued), canWait = true, queued = queued)
            Log.i(TAG, "Restored kept send ${queued.id} to ${queued.deviceId}")
        }
    }

    /** "Send now" / "Try again": every waiting send is due at once, with a fresh waiting period. */
    private fun retryAllNow() {
        for (item in items) {
            item.waitingSinceMs = null
            item.retryDelayMs = FIRST_RETRY_MS
        }
    }

    private fun discardParked() {
        notifications.cancel(PARKED_NOTIFICATION_ID)
        val parked = outgoingStore.items.value.filter { queued -> items.none { it.id == queued.id } }
        if (parked.isEmpty()) return
        Log.i(TAG, "Discarding ${parked.size} kept send(s)")
        scope.launch(Dispatchers.IO) { parked.forEach { outgoingStore.remove(it.id) } }
    }

    private fun cancelAll() {
        Log.i(TAG, "Cancelling ${items.size} send(s)")
        spoolJob?.cancel()
        items.toList().forEach(::drop)
        manager.cancel()
    }

    /** Forgets [item] and deletes its kept copy. */
    private fun drop(item: OutgoingTransfer) {
        items.remove(item)
        val queued = item.queued ?: return
        scope.launch(Dispatchers.IO) { outgoingStore.remove(queued.id) }
    }

    /**
     * A Mac has files for this phone (its pending delivery was seen, or the user tapped the
     * notification): connect to it — or, when unknown, to every Mac that can send — and take them.
     */
    private fun enqueueReceive(deviceId: String?) {
        notifications.cancel(INCOMING_NOTIFICATION_ID)
        val macs = if (deviceId != null) {
            listOfNotNull(container.trustedDeviceStore.find(deviceId))
        } else {
            container.trustedDeviceStore.devices.value.filter { it.canSend }
                .sortedWith(compareByDescending<TrustedDevice> { it.isDefault }.thenByDescending { it.lastSeenMs })
        }
        for (mac in macs) {
            if (mac.deviceId !in receiveQueue && receiving?.deviceId != mac.deviceId) receiveQueue.addLast(mac.deviceId)
        }
        Log.i(TAG, "Receiving from ${receiveQueue.size} Mac(s)")
    }

    /** Starts the next due send when the manager is free; otherwise keeps waiting ones scheduled. */
    private fun pump() {
        if (current != null || receiving != null || spoolJob != null || manager.isBusy) return
        // A Mac is waiting for this phone to take its files: that goes first.
        while (receiveQueue.isNotEmpty()) {
            val mac = container.trustedDeviceStore.find(receiveQueue.removeFirst()) ?: continue
            if (!manager.receive(mac, mac.receiveAutomatically)) {
                receiveQueue.addFirst(mac.deviceId)
                return
            }
            receiving = mac
            currentDeviceName = mac.deviceName
            acquireLocks()
            return
        }
        val now = SystemClock.elapsedRealtime()
        park(items.filter { item -> item.waitingSinceMs?.let { now - it >= MAX_WAIT_MS } == true })
        while (true) {
            val next = items.firstOrNull { it.isDue(now) } ?: break
            val device = container.trustedDeviceStore.find(next.deviceId)
            if (device == null) {
                drop(next)
                postResult(towards(getString(R.string.notification_unknown_device)), getString(R.string.notification_not_sent), getString(R.string.error_not_paired), failed = true)
                continue
            }
            // Every due share to this device goes in one transfer: the receiver asks once.
            val batchItems = if (next.joinsBatches) {
                items.filter { it.deviceId == next.deviceId && it.isDue(now) && it.joinsBatches }
            } else {
                listOf(next)
            }
            val source = if (next.joinsBatches) {
                BatchSource(next.source).apply { batchItems.drop(1).forEach { tryAdd(it.source) } }
            } else {
                next.source
            }
            // False only while a pair-only session from the app runs; its Idle state pumps again.
            if (!manager.send(SendTarget.Trusted(device), source)) return
            batchItems.forEach { it.lastAttemptMs = now }
            current = Batch(next.deviceId, source, batchItems.toMutableList())
            currentDeviceName = device.deviceName
            if (batchItems.size > 1) Log.i(TAG, "Sending ${batchItems.size} shares to ${next.deviceId} as one transfer")
            acquireLocks()
            break
        }
        scheduleWaiting()
    }

    /** Runs the watcher and the retry timer while something waits, and shows that it waits. */
    private fun scheduleWaiting() {
        val waiting = items.filter { it.waitingSinceMs != null && !isCurrent(it) }
        retryJob?.cancel()
        retryJob = null
        if (waiting.isEmpty()) {
            watchJob?.cancel()
            watchJob = null
            return
        }
        if (watchJob == null) {
            // Low latency for the first minutes of waiting (balanced mode missed a woken Mac for
            // 20+ s), counted from when the oldest send started waiting, not from each retry.
            val closeUntil = waiting.minOf { it.waitingSinceMs!! } + CLOSE_WATCH_MS
            watchJob = scope.launch { container.availabilityWatcher.triggers(closeUntil).collect(::onTrigger) }
        }
        val now = SystemClock.elapsedRealtime()
        val nextAt = waiting.minOf { minOf(it.retryAtMs, it.waitingSinceMs!! + MAX_WAIT_MS) }
        retryJob = scope.launch {
            delay((nextAt - now).coerceAtLeast(0) + TIMER_SLACK_MS)
            retryJob = null
            pump()
            stopIfIdle()
        }
        if (current == null) showWaiting(waiting)
    }

    private fun onTrigger(trigger: AvailabilityTrigger) {
        val now = SystemClock.elapsedRealtime()
        val woken = items.filter { item ->
            item.waitingSinceMs != null && !isCurrent(item) &&
                (trigger is AvailabilityTrigger.NetworkChanged || (trigger as AvailabilityTrigger.DeviceAvailable).deviceId == item.deviceId)
        }
        if (woken.isEmpty()) return
        woken.forEach { it.retryAtMs = maxOf(now, it.lastAttemptMs + MIN_ATTEMPT_GAP_MS) }
        Log.i(TAG, "Retrying ${woken.size} waiting send(s): $trigger")
        pump()
    }

    private fun onState(state: TransferState) {
        if (receiving != null) {
            onReceiveState(state)
            return
        }
        // States of sessions this service didn't start (pair-only from the app) aren't ours.
        // Stopping is decided only after start commands are handled (onStartCommand, finishCurrent);
        // this collector already sees Idle in onCreate, before the first command is queued.
        if (current == null) {
            if (state is TransferState.Idle) pump()
            return
        }
        if (state !is TransferState.Pairing) notifications.cancel(PAIRING_NOTIFICATION_ID)
        when {
            // While a copy for later is being made, the copy finishes the send instead.
            state is TransferState.Idle -> if (spoolJob == null) finishCurrent()
            state.isFinal() -> {
                handleOutcome(state)
                manager.dismiss()
            }
            else -> {
                if (state is TransferState.Pairing) showPairing(state)
                updateOngoing(state)
            }
        }
    }

    private fun handleOutcome(state: TransferState) {
        val batch = current ?: return
        val included = manager.lastIncluded
        // Shares that joined after the receiver decided weren't part of this outcome: they go next.
        val (affected, late) = batch.items.partition { item -> included.any { it === item.source } }
        late.forEach { it.retryAtMs = 0 }
        val owned = affected.filter { it in items }
        if (state is TransferState.Failed && state.error.isTemporary && owned.isNotEmpty() && owned.all { it.canWait }) {
            owned.forEach { startWaiting(it, state.error) }
            spoolWaiting()
            return
        }
        owned.forEach(::drop)
        postFinalState(state, batch.source.clipboardText)
        if (state is TransferState.Completed || state is TransferState.TextCopied) {
            // The device is reachable right now: its other waiting sends go next.
            items.filter { it.deviceId == batch.deviceId && it.waitingSinceMs != null }.forEach { it.retryAtMs = 0 }
        }
    }

    private fun startWaiting(item: OutgoingTransfer, error: ConnectionException) {
        val now = SystemClock.elapsedRealtime()
        val bluetoothWatches = container.bluetoothEnvironment.currentBlocker() == null
        if (item.waitingSinceMs == null) {
            item.waitingSinceMs = now
            item.retryDelayMs = if (bluetoothWatches) FIRST_RETRY_WATCHED_MS else FIRST_RETRY_MS
        }
        item.retryAtMs = now + item.retryDelayMs
        Log.i(TAG, "Send ${item.id} waits for ${item.deviceId} (${error.message}); next timed try in ${item.retryDelayMs / 1000} s")
        item.retryDelayMs = minOf(item.retryDelayMs * 2, if (bluetoothWatches) MAX_RETRY_WATCHED_MS else MAX_RETRY_DELAY_MS)
        // The device's other sends would fail the same way: they wait with it.
        items.filter { it !== item && it.deviceId == item.deviceId && it.canWait && it.waitingSinceMs == null }.forEach {
            it.waitingSinceMs = now
            it.retryAtMs = item.retryAtMs
        }
    }

    /** Copies every waiting send that is still read from its share grant. Holds [current] until done. */
    private fun spoolWaiting() {
        fun needsCopy(item: OutgoingTransfer) = item.waitingSinceMs != null && item.queued == null && item.canWait && !item.spoolFailed
        // Nothing to copy: the manager's Idle state finishes the send as usual.
        if (spoolJob != null || items.none(::needsCopy)) return
        spoolJob = scope.launch {
            try {
                while (true) {
                    val item = items.firstOrNull(::needsCopy) ?: break
                    showSpooling(item)
                    try {
                        val queued = withContext(Dispatchers.IO) { outgoingStore.spool(item.id, item.deviceId, item.source) }
                        if (item in items) {
                            item.queued = queued
                            item.source = outgoingStore.source(queued)
                        } else {
                            withContext(Dispatchers.IO) { outgoingStore.remove(queued.id) }
                        }
                    } catch (e: SpoolSpaceException) {
                        Log.w(TAG, "No space to keep ${item.id} for later (${e.needed} bytes needed, ${e.available} free)")
                        item.spoolFailed = true
                    } catch (e: IOException) {
                        Log.w(TAG, "Could not keep ${item.id} for later: ${e.message}")
                        item.spoolFailed = true
                    }
                }
            } finally {
                spoolJob = null
                if (current != null && !manager.isBusy) {
                    finishCurrent()
                } else {
                    pump()
                    stopIfIdle()
                }
            }
        }
    }

    /** Sends past their waiting period leave memory; kept copies stay on disk for "Try again". */
    private fun park(expired: List<OutgoingTransfer>) {
        if (expired.isEmpty()) return
        items.removeAll(expired)
        val (kept, lost) = expired.partition { it.queued != null }
        Log.i(TAG, "Parking ${kept.size} kept send(s); ${lost.size} without a copy are given up")
        lost.forEach { item ->
            val name = deviceName(item.deviceId)
            postResult(towards(name), getString(R.string.notification_not_sent), getString(R.string.queue_not_kept, name), failed = true)
        }
        if (kept.isNotEmpty()) showParked(kept)
    }

    private fun onReceiveState(state: TransferState) {
        if (state !is TransferState.AwaitingLocalDecision) notifications.cancel(INCOMING_SUMMARY_ID)
        when {
            state is TransferState.Idle -> {
                receiving = null
                notifications.cancel(INCOMING_NOTIFICATION_ID)
                releaseLocks()
                pump()
                stopIfIdle()
                // The ongoing notification still shows the request (see showIncoming) if it was
                // declined: it must not stay on screen while queued sends keep the service up.
                if (incomingAlerted && inForeground) updateOngoing(TransferState.Preparing(currentDeviceName))
                incomingAlerted = false
            }
            state.isFinal() -> {
                notifications.cancel(INCOMING_NOTIFICATION_ID)
                postReceiveResult(state)
                manager.dismiss()
            }
            state is TransferState.AwaitingLocalDecision -> showIncoming(state)
            else -> {
                incomingAlerted = false
                notifications.cancel(INCOMING_NOTIFICATION_ID)
                updateOngoing(state)
            }
        }
    }

    private fun finishCurrent() {
        current = null
        releaseLocks()
        pump()
        stopIfIdle()
    }

    private fun stopIfIdle() {
        if (current == null && items.isEmpty() && spoolJob == null && !manager.isBusy && receiving == null && receiveQueue.isEmpty()) {
            watchJob?.cancel()
            watchJob = null
            retryJob?.cancel()
            retryJob = null
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            inForeground = false
            stopSelf()
        }
    }

    private fun deviceName(deviceId: String): String =
        container.trustedDeviceStore.find(deviceId)?.deviceName ?: getString(R.string.notification_unknown_device)

    // region Notifications

    private fun startForegroundIfNeeded() {
        if (inForeground) return
        val notification = ongoingBuilder()
            .setContentTitle(getString(R.string.notification_preparing))
            .setProgress(0, 0, true)
            .build()
        ServiceCompat.startForeground(this, ONGOING_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        inForeground = true
    }

    private fun updateOngoing(state: TransferState) {
        // Android drops every update from a package posting more than ~5 per second, so progress
        // (emitted 10× a second for the in-app screen) is shown at most once a second.
        if (state is TransferState.Transferring || state is TransferState.Receiving) {
            val now = SystemClock.elapsedRealtime()
            if (now - lastProgressNotificationMs < PROGRESS_NOTIFICATION_INTERVAL_MS) return
            lastProgressNotificationMs = now
        } else {
            lastProgressNotificationMs = 0
        }
        val name = currentDeviceName
        val sending = receiving == null
        val builder = ongoingBuilder(if (sending) towards(name) else from(name))
        when (state) {
            is TransferState.Connecting -> builder.setContentTitle(getString(R.string.notification_connecting)).setProgress(0, 0, true)
            is TransferState.Pairing -> builder.setContentTitle(getString(R.string.notification_pairing_title, name))
                .setContentText(getString(R.string.notification_pairing_text))
            is TransferState.Preparing -> builder.setContentTitle(getString(R.string.transfer_preparing)).setProgress(0, 0, true)
            is TransferState.AwaitingApproval -> {
                // Grows as more shares are added to the request on the Mac's screen.
                val summary = state.summary
                builder.setContentTitle(TransferText.what(this, summary.fileCount, summary.firstFileName))
                    .setContentText(getString(R.string.notification_awaiting_mac))
                    .setProgress(0, 0, true)
            }
            is TransferState.Transferring -> builder.transferProgress(state.progress, sending = true)
            is TransferState.Verifying -> builder.setContentTitle(TransferText.what(this, state.progress.fileCount, state.progress.currentFileName))
                .setContentText(getString(R.string.transfer_verifying))
                .setProgress(0, 0, true)
            is TransferState.Receiving -> builder.transferProgress(state.progress, sending = false)
            else -> return
        }
        // A Live Update from the first step to the last: it stays in one place at the top of the
        // shade instead of starting among silent notifications and jumping up once data flows.
        builder.setRequestPromotedOngoing(true)
        builder.addAction(0, getString(R.string.action_cancel), serviceIntent(ACTION_CANCEL, REQUEST_CANCEL))
        notifyIfAllowed(ONGOING_NOTIFICATION_ID, builder.build())
    }

    /** The code is compared with the Mac's screen; confirming here avoids opening the app. */
    private fun showPairing(state: TransferState.Pairing) {
        val builder = NotificationCompat.Builder(this, CHANNEL_PAIRING)
            .setSmallIcon(R.drawable.ic_stat_localdrop)
            .setContentTitle(getString(R.string.notification_pairing_code, state.code))
            .setContentText(getString(R.string.pairing_compare, state.peer.name))
            .setStyle(NotificationCompat.BigTextStyle().bigText(
                if (state.keyChanged) getString(R.string.pairing_key_changed, state.peer.name) + "\n\n" + getString(R.string.pairing_compare, state.peer.name)
                else getString(R.string.pairing_compare, state.peer.name),
            ))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            // The code is shown only to the unlocked owner.
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent())
        if (state.confirmedLocally) {
            builder.setContentText(getString(R.string.pairing_waiting, state.peer.name))
                .addAction(0, getString(R.string.action_cancel), serviceIntent(ACTION_DECLINE_PAIRING, REQUEST_DECLINE))
        } else {
            builder.addAction(0, getString(R.string.action_decline), serviceIntent(ACTION_DECLINE_PAIRING, REQUEST_DECLINE))
                .addAction(0, getString(R.string.action_pair), serviceIntent(ACTION_CONFIRM_PAIRING, REQUEST_CONFIRM))
        }
        notifyIfAllowed(PAIRING_NOTIFICATION_ID, builder.build())
    }

    private fun showWaiting(waiting: List<OutgoingTransfer>) {
        val names = waiting.map { deviceName(it.deviceId) }.distinct().joinToString()
        val count = waiting.sumOf { it.queued?.itemCount ?: 1 }
        val notification = ongoingBuilder()
            .setSubText(towards(names))
            .setContentTitle(resources.getQuantityString(R.plurals.notification_queue_title, count, count))
            .setContentText(getString(R.string.notification_queue_text))
            .addAction(0, getString(R.string.action_cancel), serviceIntent(ACTION_CANCEL, REQUEST_CANCEL))
            .addAction(0, getString(R.string.action_send_now), serviceIntent(ACTION_RESUME, REQUEST_RESUME))
            .build()
        notifyIfAllowed(ONGOING_NOTIFICATION_ID, notification)
    }

    private fun showSpooling(item: OutgoingTransfer) {
        val notification = ongoingBuilder()
            .setSubText(towards(deviceName(item.deviceId)))
            .setContentTitle(getString(R.string.notification_queue_saving))
            .setContentText(getString(R.string.queue_spooling))
            .setProgress(0, 0, true)
            .addAction(0, getString(R.string.action_cancel), serviceIntent(ACTION_CANCEL, REQUEST_CANCEL))
            .build()
        notifyIfAllowed(ONGOING_NOTIFICATION_ID, notification)
    }

    private fun showParked(parked: List<OutgoingTransfer>) {
        val names = parked.map { deviceName(it.deviceId) }.distinct().joinToString()
        val text = getString(R.string.queue_parked_text, names)
        val notification = resultBuilder(towards(names))
            .setAutoCancel(false)
            .setContentTitle(getString(R.string.notification_not_sent))
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openAppIntent())
            .addAction(0, getString(R.string.action_discard), serviceIntent(ACTION_DISCARD, REQUEST_DISCARD))
            .addAction(0, getString(R.string.action_try_again), serviceIntent(ACTION_RESUME, REQUEST_RESUME))
            .build()
        notifyIfAllowed(PARKED_NOTIFICATION_ID, notification)
    }

    private fun postFinalState(state: TransferState, sentText: String?) {
        val name = currentDeviceName
        when (state) {
            is TransferState.Completed -> {
                val summary = state.summary
                history.add(
                    incoming = false,
                    peerName = name,
                    kind = HistoryEntry.Kind.FILES,
                    title = summary.firstFileName,
                    count = summary.fileCount,
                    bytes = summary.totalBytes,
                    durationMs = state.durationMs,
                )
                postResult(
                    towards(name),
                    TransferText.what(this, summary.fileCount, summary.firstFileName),
                    getString(
                        R.string.notification_sent,
                        Formatter.formatShortFileSize(this, summary.totalBytes),
                        TransferText.duration(this, state.durationMs),
                    ),
                )
            }
            is TransferState.TextCopied -> {
                sentText?.let { history.add(incoming = false, peerName = name, kind = textKind(it), title = it.trim()) }
                postResult(towards(name), getString(R.string.notification_copied), getString(R.string.text_copied_body))
            }
            is TransferState.Failed -> postResult(towards(name), getString(R.string.notification_not_sent), TransferText.error(this, state.error, name), failed = true)
            is TransferState.Cancelled -> if (state.byPeer) {
                postResult(towards(name), getString(R.string.transfer_cancelled), getString(R.string.transfer_cancelled_by_peer, name))
            }
            else -> Unit
        }
    }

    /**
     * The Mac's offer, with visible Accept and Decline; it is also the transfer screen's prompt.
     * It takes the place of the service's ongoing notification, so the request isn't shown twice;
     * once answered, that notification goes back to showing progress.
     */
    private var incomingAlerted = false

    private fun showIncoming(state: TransferState.AwaitingLocalDecision) {
        val notification = NotificationCompat.Builder(this, CHANNEL_INCOMING)
            .setSmallIcon(R.drawable.ic_stat_localdrop)
            .setSubText(from(state.peerName))
            .setContentTitle(TransferText.what(this, state.summary.fileCount, state.summary.firstFileName))
            .setContentText(getString(R.string.notification_incoming_text, Formatter.formatShortFileSize(this, state.summary.totalBytes)))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setOngoing(true)
            // It replaces the silent ongoing notification, which is already showing, so "only
            // alert once" would keep it quiet: it sounds and pops up for a new request only, not
            // when files are added to the one on screen.
            .setOnlyAlertOnce(incomingAlerted)
            // In a group of its own (see incomingGroupSummary), alerting itself.
            .setGroup(INCOMING_GROUP)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setContentIntent(openAppIntent())
            .addAction(0, getString(R.string.action_decline), serviceIntent(ACTION_DECLINE_INCOMING, REQUEST_DECLINE_INCOMING))
            .addAction(0, getString(R.string.action_accept), serviceIntent(ACTION_ACCEPT_INCOMING, REQUEST_ACCEPT_INCOMING))
            .build()
        notifyIfAllowed(INCOMING_SUMMARY_ID, incomingGroupSummary())
        notifyIfAllowed(ONGOING_NOTIFICATION_ID, notification)
        incomingAlerted = true
    }

    /**
     * Android bundles an app's notifications in the same section — here with results still in
     * the shade — and lets the bundle alert instead; an existing bundle can update silently, and
     * the request then arrived without waking the screen. A group with its own summary is kept
     * as it is, so the request stands alone and makes its own sound.
     */
    private fun incomingGroupSummary(): Notification = NotificationCompat.Builder(this, CHANNEL_INCOMING)
        .setSmallIcon(R.drawable.ic_stat_localdrop)
        .setGroup(INCOMING_GROUP)
        .setGroupSummary(true)
        .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
        .build()

    private fun postReceiveResult(state: TransferState) {
        val name = currentDeviceName
        when (state) {
            is TransferState.Received -> {
                state.texts.forEach { history.add(incoming = true, peerName = name, kind = textKind(it), title = it.trim()) }
                if (state.texts.isNotEmpty()) postTextReceived(state.texts.last(), name)
                val files = state.files
                if (files.isEmpty()) return
                val first = files.first()
                history.add(
                    incoming = true,
                    peerName = name,
                    kind = HistoryEntry.Kind.FILES,
                    title = first.name,
                    count = files.size,
                    uri = first.uri.toString().takeIf { files.size == 1 },
                    mimeType = first.mimeType.takeIf { files.size == 1 },
                    bytes = files.sumOf { it.size },
                )
                // An app installs only from an app allowed to install, which LocalDrop doesn't ask to
                // be: Files is, and opens the installer when the APK is tapped in Downloads.
                val isApp = files.size == 1 && (first.mimeType == APK_MIME_TYPE || first.name.endsWith(".apk", ignoreCase = true))
                // One file opens in its app; several (or an app to install) open the Downloads list.
                val open = if (files.size == 1 && !isApp) {
                    Intent(Intent.ACTION_VIEW).setDataAndType(first.uri, first.mimeType).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } else {
                    Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
                }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                val openIntent = PendingIntent.getActivity(this, REQUEST_OPEN_RECEIVED, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                val text = getString(if (isApp) R.string.notification_received_app else R.string.notification_received)
                val builder = resultBuilder(from(name))
                    .setContentTitle(TransferText.what(this, files.size, first.name))
                    .setContentText(text)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                    .setContentIntent(openIntent)
                    .addAction(0, getString(if (isApp) R.string.action_show_downloads else R.string.action_open), openIntent)
                if (files.size == 1 && !isApp) {
                    thumbnail(first.uri)?.let(builder::setLargeIcon)
                    val share = Intent.createChooser(
                        Intent(Intent.ACTION_SEND).setType(first.mimeType).putExtra(Intent.EXTRA_STREAM, first.uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                        null,
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    builder.addAction(0, getString(R.string.action_share), PendingIntent.getActivity(this, REQUEST_SHARE_RECEIVED, share, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
                }
                val notification = builder.build()
                notifyIfAllowed(resultNotificationId++, notification)
            }
            is TransferState.Failed -> postResult(from(name), getString(R.string.notification_not_received), TransferText.error(this, state.error, name), failed = true)
            is TransferState.Cancelled -> if (state.byPeer) {
                postResult(from(name), getString(R.string.transfer_cancelled), getString(R.string.transfer_cancelled_by_peer, name))
            }
            else -> Unit
        }
    }

    /**
     * Text or a link from the Mac, put on the clipboard. A link opens only when tapped, as on the
     * Mac (messages.md `text`).
     */
    private fun postTextReceived(text: String, name: String) {
        getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText(getString(R.string.app_name), text))
        val link = webLink(text)
        val preview = text.trim().take(TEXT_PREVIEW_LENGTH)
        val builder = resultBuilder(from(name))
            .setContentTitle(getString(if (link != null) R.string.notification_link_copied else R.string.notification_text_copied))
            .setContentText(preview)
            .setStyle(NotificationCompat.BigTextStyle().bigText(preview))
        if (link != null) {
            val open = PendingIntent.getActivity(
                this,
                REQUEST_OPEN_LINK,
                Intent(Intent.ACTION_VIEW, link).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            builder.setContentIntent(open).addAction(0, getString(R.string.action_open), open)
        }
        notifyIfAllowed(resultNotificationId++, builder.build())
    }

    private fun textKind(text: String) = if (webLink(text) != null) HistoryEntry.Kind.LINK else HistoryEntry.Kind.TEXT

    private fun postResult(direction: String, title: String, text: String, failed: Boolean = false) {
        val notification = resultBuilder(direction)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .apply { if (failed) setColor(ContextCompat.getColor(this@TransferService, R.color.notification_error)) }
            .build()
        notifyIfAllowed(resultNotificationId++, notification)
        if (!notifications.areNotificationsEnabled()) {
            Toast.makeText(this, "$title. $text", Toast.LENGTH_LONG).show()
        }
    }

    /** The header line: where files go, or where they come from. */
    private fun towards(name: String) = getString(R.string.notification_towards, name)

    private fun from(name: String) = getString(R.string.notification_from, name)

    /**
     * A transfer under way: what, how long is left, and progress that stays in sight, like the
     * filling drop in the Mac's menu bar. On Android 16+ a Live Update: a status bar chip with
     * the time left, pinned to the top of the shade and shown on the lock screen; a dot travels
     * along the bar from the Mac or to it, one segment per file. Older versions
     * show the usual progress bar.
     */
    private fun NotificationCompat.Builder.transferProgress(progress: TransferProgress, sending: Boolean): NotificationCompat.Builder {
        val total = progress.totalBytes.coerceAtLeast(1)
        val percent = (progress.bytesSent * 100 / total).toInt().coerceIn(0, 100)
        val sizes = progress.fileSizes.takeIf { it.size in 2..MAX_PROGRESS_SEGMENTS }
        val segments = sizes?.map { NotificationCompat.ProgressStyle.Segment((it * PROGRESS_SCALE / total).toInt().coerceAtLeast(1))}
            ?: listOf(NotificationCompat.ProgressStyle.Segment(PROGRESS_SCALE))
        val scale = segments.sumOf { it.length }
        // Only the other device: the phone is the one in hand. It stands on its side of the flow,
        // at the start when files come from it, at the end when they go to it.
        val peer = IconCompat.createWithResource(this@TransferService, R.drawable.ic_progress_laptop)
        val style = NotificationCompat.ProgressStyle()
            .setProgressSegments(segments)
            .setProgress((progress.bytesSent.toDouble() / total * scale).toInt().coerceIn(0, scale))
            .setProgressTrackerIcon(IconCompat.createWithResource(this@TransferService, R.drawable.ic_progress_tracker))
        if (sending) style.setProgressEndIcon(peer) else style.setProgressStartIcon(peer)
        return setContentTitle(TransferText.what(this@TransferService, progress.fileCount, progress.currentFileName))
            .setContentText(TransferText.notificationLine(this@TransferService, progress))
            .setProgress(100, percent, false)
            .setStyle(style)
            .setRequestPromotedOngoing(true)
            .setShortCriticalText(TransferText.chipTimeLeft(this@TransferService, progress) ?: "$percent%")
    }

    private fun ongoingBuilder(direction: String? = null) = NotificationCompat.Builder(this, CHANNEL_PROGRESS)
        .setSmallIcon(R.drawable.ic_stat_localdrop)
        .setSubText(direction)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        .setContentIntent(openAppIntent())

    private fun resultBuilder(direction: String) = NotificationCompat.Builder(this, CHANNEL_RESULTS)
        .setSmallIcon(R.drawable.ic_stat_localdrop)
        .setSubText(direction)
        .setAutoCancel(true)
        .setContentIntent(openAppIntent())

    /** A received photo or video, small, for the notification; null for other files. */
    private fun thumbnail(uri: Uri): Bitmap? = try {
        contentResolver.loadThumbnail(uri, Size(THUMBNAIL_SIZE, THUMBNAIL_SIZE), null)
    } catch (e: IOException) {
        null
    }

    private fun notifyIfAllowed(id: Int, notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        notifications.notify(id, notification)
    }

    private fun serviceIntent(action: String, requestCode: Int): PendingIntent = PendingIntent.getService(
        this,
        requestCode,
        Intent(this, TransferService::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        REQUEST_OPEN,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    // endregion

    // region Locks

    /** Keeps the CPU and Wi-Fi awake while data flows with the screen off. Released on finish. */
    private fun acquireLocks() {
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LocalDrop:transfer")
                .apply { acquire(MAX_LOCK_MS) }
        }
        if (wifiLock == null && Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            @Suppress("DEPRECATION") // Non-functional from API 34, where the platform keeps Wi-Fi up for active traffic.
            wifiLock = getSystemService(WifiManager::class.java)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "LocalDrop:transfer")
                .apply { acquire() }
        }
    }

    private fun releaseLocks() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
    }

    // endregion

    companion object {
        private const val TAG = "LD/transfer"
        private const val ACTION_SEND = "dev.localdrop.action.SEND"
        private const val ACTION_CANCEL = "dev.localdrop.action.CANCEL"
        private const val ACTION_RESUME = "dev.localdrop.action.RESUME"
        private const val ACTION_DISCARD = "dev.localdrop.action.DISCARD"
        private const val ACTION_RECEIVE = "dev.localdrop.action.RECEIVE"
        private const val ACTION_ACCEPT_INCOMING = "dev.localdrop.action.ACCEPT_INCOMING"
        private const val ACTION_DECLINE_INCOMING = "dev.localdrop.action.DECLINE_INCOMING"
        private const val ACTION_CONFIRM_PAIRING = "dev.localdrop.action.CONFIRM_PAIRING"
        private const val ACTION_DECLINE_PAIRING = "dev.localdrop.action.DECLINE_PAIRING"
        private const val EXTRA_DEVICE_ID = "deviceId"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_TEST_SIZE = "testSize"

        private const val CHANNEL_PROGRESS = "transfer_progress"
        private const val CHANNEL_RESULTS = "transfer_results"
        private const val CHANNEL_PAIRING = "pairing"
        const val CHANNEL_INCOMING = "incoming"
        const val INCOMING_NOTIFICATION_ID = 4
        const val INCOMING_GROUP = "incoming"
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        private const val INCOMING_SUMMARY_ID = 5
        private const val ONGOING_NOTIFICATION_ID = 1
        private const val PAIRING_NOTIFICATION_ID = 2
        private const val PARKED_NOTIFICATION_ID = 3
        private const val RESULT_NOTIFICATION_BASE = 100
        private const val REQUEST_CANCEL = 1
        private const val REQUEST_CONFIRM = 2
        private const val REQUEST_DECLINE = 3
        private const val REQUEST_OPEN = 4
        private const val REQUEST_RESUME = 5
        private const val REQUEST_DISCARD = 6
        private const val REQUEST_ACCEPT_INCOMING = 7
        private const val REQUEST_DECLINE_INCOMING = 8
        private const val REQUEST_OPEN_RECEIVED = 9
        private const val REQUEST_OPEN_LINK = 30
        private const val REQUEST_SHARE_RECEIVED = 31
        private const val THUMBNAIL_SIZE = 256
        /** Progress units across the bar; segments split it by file size. */
        private const val PROGRESS_SCALE = 1000
        /** More files than this show as one segment: thin slivers say nothing. */
        private const val MAX_PROGRESS_SEGMENTS = 10
        private const val TEXT_PREVIEW_LENGTH = 300
        private const val REQUEST_RECEIVE = 10
        private const val TIMER_SLACK_MS = 50L
        private const val PROGRESS_NOTIFICATION_INTERVAL_MS = 1_000L
        private const val MAX_LOCK_MS = 6 * 60 * 60 * 1000L

        /** Sends items shared from another app; [uris] keep their read grant via the intent's ClipData. */
        fun sendShared(context: Context, deviceId: String, uris: List<Uri>, text: String?) {
            val intent = Intent(context, TransferService::class.java)
                .setAction(ACTION_SEND)
                .putExtra(EXTRA_DEVICE_ID, deviceId)
                .putExtra(EXTRA_TEXT, text)
            if (uris.isNotEmpty()) {
                val clip = ClipData.newRawUri(null, uris.first())
                uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
                intent.clipData = clip
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        /**
         * Takes the files a Mac has for this phone. Allowed from the background only with a
         * companion-device association; callers fall back to [receiveOnTap].
         */
        fun receive(context: Context, deviceId: String? = null) {
            ContextCompat.startForegroundService(context, receiveIntent(context, deviceId))
        }

        /** The same, started by a tap on a notification (always allowed). */
        fun receiveOnTap(context: Context): PendingIntent =
            PendingIntent.getForegroundService(context, REQUEST_RECEIVE, receiveIntent(context, null), PendingIntent.FLAG_IMMUTABLE)

        private fun receiveIntent(context: Context, deviceId: String?) =
            Intent(context, TransferService::class.java).setAction(ACTION_RECEIVE).putExtra(EXTRA_DEVICE_ID, deviceId)

        /** Retries kept sends now (LocalDrop was opened). Call only from the foreground. */
        fun resume(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, TransferService::class.java).setAction(ACTION_RESUME))
        }

        fun sendTestData(context: Context, deviceId: String, sizeBytes: Long) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, TransferService::class.java)
                    .setAction(ACTION_SEND)
                    .putExtra(EXTRA_DEVICE_ID, deviceId)
                    .putExtra(EXTRA_TEST_SIZE, sizeBytes),
            )
        }

        fun createChannels(context: Context) {
            NotificationManagerCompat.from(context).createNotificationChannelsCompat(
                listOf(
                    NotificationChannelCompat.Builder(CHANNEL_PROGRESS, NotificationManagerCompat.IMPORTANCE_LOW)
                        .setName(context.getString(R.string.channel_progress)).build(),
                    NotificationChannelCompat.Builder(CHANNEL_RESULTS, NotificationManagerCompat.IMPORTANCE_DEFAULT)
                        .setName(context.getString(R.string.channel_results)).build(),
                    NotificationChannelCompat.Builder(CHANNEL_PAIRING, NotificationManagerCompat.IMPORTANCE_HIGH)
                        .setName(context.getString(R.string.channel_pairing)).build(),
                    NotificationChannelCompat.Builder(CHANNEL_INCOMING, NotificationManagerCompat.IMPORTANCE_HIGH)
                        .setName(context.getString(R.string.channel_incoming)).build(),
                ),
            )
        }
    }
}
