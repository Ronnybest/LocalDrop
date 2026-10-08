package dev.localdrop.core.queue

import android.util.Log
import androidx.core.util.AtomicFile
import dev.localdrop.core.protocol.Cbor
import dev.localdrop.core.protocol.CborException
import dev.localdrop.core.protocol.CborValue
import dev.localdrop.core.protocol.array
import dev.localdrop.core.protocol.text
import dev.localdrop.core.protocol.uint
import dev.localdrop.core.transfer.SourceFile
import dev.localdrop.core.transfer.TransferSource
import dev.localdrop.core.transfer.textSourceFile
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A file copied into the spool; sent from there instead of its temporary `content://` grant. */
class QueuedFile(val name: String, val mimeType: String, val size: Long, val lastModified: Long?, val fileName: String)

/** A send waiting for its device. Self-contained: it outlives the share's URI grant and the process. */
class QueuedTransfer(
    val id: String,
    val deviceId: String,
    val createdAtMs: Long,
    val files: List<QueuedFile>,
    /** Text for the receiver's clipboard; set only when there are no files. */
    val text: String?,
) {
    val itemCount: Int get() = if (text != null) 1 else files.size
}

/** Not enough free space on this phone to keep a copy for later. */
class SpoolSpaceException(val needed: Long, val available: Long) :
    IOException("Spool needs $needed bytes, $available available")

/**
 * Sends kept for later (protocol-independent; architecture.md §8, Milestone 8). Each one is a
 * directory under [root] with its files (`f0`, `f1`, …) and a `manifest.cbor` written last and
 * atomically: a directory without a manifest is an interrupted copy and is deleted on load.
 * [root] is in `noBackupFilesDir`, so the system never clears it as cache and it is never backed up.
 */
class OutgoingStore(private val root: File, private val clock: () -> Long = System::currentTimeMillis) {

    private val _items = MutableStateFlow<List<QueuedTransfer>>(emptyList())

    /** Persisted sends, oldest first. */
    val items: StateFlow<List<QueuedTransfer>> = _items.asStateFlow()
    private var loaded = false

    @Synchronized
    fun load() {
        if (loaded) return
        loaded = true
        val now = clock()
        val dirs = root.listFiles { file -> file.isDirectory }.orEmpty()
        val items = dirs.mapNotNull { dir ->
            val item = try {
                decode(AtomicFile(File(dir, MANIFEST)).readFully())
            } catch (e: FileNotFoundException) {
                null
            } catch (e: IOException) {
                Log.w(TAG, "Unreadable queued send ${dir.name}: ${e.message}")
                null
            } catch (e: CborException) {
                Log.w(TAG, "Corrupt queued send ${dir.name}: ${e.message}")
                null
            }
            when {
                item == null -> {
                    deleteDir(dir)
                    null
                }
                now - item.createdAtMs > MAX_AGE_MS -> {
                    Log.i(TAG, "Queued send ${item.id} expired; deleting")
                    deleteDir(dir)
                    null
                }
                else -> item
            }
        }
        _items.value = items.sortedBy { it.createdAtMs }
        if (items.isNotEmpty()) Log.i(TAG, "Loaded ${items.size} queued send(s)")
    }

    /**
     * Copies [source] into the spool. Text small enough for the clipboard is kept as text.
     * Runs on an I/O thread; cancellation removes the partial copy.
     * @throws SpoolSpaceException if the copy would leave less than [MIN_FREE_BYTES] free.
     * @throws IOException if the source can't be read or the copy fails.
     */
    suspend fun spool(id: String, deviceId: String, source: TransferSource): QueuedTransfer {
        load()
        val dir = File(root, id)
        deleteDir(dir)
        if (!dir.mkdirs()) throw IOException("Cannot create ${dir.path}")
        try {
            val text = source.clipboardText
            val files = if (text != null) emptyList() else copyFiles(source, dir)
            val item = QueuedTransfer(id, deviceId, clock(), files, text)
            writeManifest(dir, item)
            synchronized(this) { _items.value = (_items.value.filter { it.id != id } + item).sortedBy { it.createdAtMs } }
            Log.i(TAG, "Kept ${item.itemCount} item(s) (${files.sumOf { it.size }} bytes) for later: $id")
            return item
        } catch (e: Throwable) {
            deleteDir(dir)
            throw e
        }
    }

    private suspend fun copyFiles(source: TransferSource, dir: File): List<QueuedFile> {
        val files = try {
            source.files()
        } catch (e: SecurityException) {
            throw IOException("Source no longer readable", e)
        }
        val needed = files.sumOf { it.size }
        val available = dir.usableSpace
        if (available - needed < MIN_FREE_BYTES) throw SpoolSpaceException(needed, available)
        val buffer = ByteArray(COPY_BUFFER)
        return files.mapIndexed { index, file ->
            val target = File(dir, "f$index")
            var copied = 0L
            try {
                file.open().use { input ->
                    FileOutputStream(target).use { output ->
                        while (true) {
                            coroutineContext.ensureActive()
                            val n = input.read(buffer)
                            if (n < 0) break
                            output.write(buffer, 0, n)
                            copied += n
                        }
                        output.fd.sync()
                    }
                }
            } catch (e: SecurityException) {
                throw IOException("Source no longer readable", e)
            }
            // The copy is what will be sent; its length is authoritative.
            QueuedFile(file.name, file.mimeType, copied, file.lastModified, target.name)
        }
    }

    @Synchronized
    fun remove(id: String) {
        deleteDir(File(root, id))
        _items.value = _items.value.filter { it.id != id }
        Log.i(TAG, "Removed queued send $id")
    }

    /** What to send for a queued item: its spooled copies. */
    fun source(item: QueuedTransfer): TransferSource = SpooledSource(File(root, item.id), item)

    private fun writeManifest(dir: File, item: QueuedTransfer) {
        val file = AtomicFile(File(dir, MANIFEST))
        val stream = file.startWrite()
        try {
            stream.write(encode(item))
            file.finishWrite(stream)
        } catch (e: IOException) {
            file.failWrite(stream)
            throw e
        }
    }

    private fun deleteDir(dir: File) {
        if (dir.exists() && !dir.deleteRecursively()) Log.w(TAG, "Could not delete ${dir.path}")
    }

    private class SpooledSource(private val dir: File, private val item: QueuedTransfer) : TransferSource {
        override val description: String = when {
            item.text != null -> "text"
            item.files.size == 1 -> item.files.first().name
            else -> "${item.files.size} files"
        }

        override val clipboardText: String? get() = item.text

        override fun files(): List<SourceFile> {
            item.text?.let { return listOf(textSourceFile(it)) }
            return item.files.map { file ->
                SourceFile(file.name, file.mimeType, file.size, file.lastModified) { FileInputStream(File(dir, file.fileName)) }
            }
        }
    }

    companion object {
        private const val TAG = "LD/queue"
        private const val MANIFEST = "manifest.cbor"
        private const val FORMAT_VERSION = 1L
        private const val COPY_BUFFER = 256 * 1024

        /** Copies never leave less than this free: the phone needs room for everything else. */
        const val MIN_FREE_BYTES = 500L * 1024 * 1024

        /** Unsent copies are deleted after a week. */
        const val MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000

        internal fun encode(item: QueuedTransfer): ByteArray = Cbor.encode(
            CborValue.Map(
                buildMap {
                    put("version", CborValue.UInt(FORMAT_VERSION))
                    put("id", CborValue.Text(item.id))
                    put("deviceId", CborValue.Text(item.deviceId))
                    put("created", CborValue.UInt(item.createdAtMs))
                    item.text?.let { put("text", CborValue.Text(it)) }
                    put(
                        "files",
                        CborValue.Array(
                            item.files.map { file ->
                                CborValue.Map(
                                    buildMap {
                                        put("name", CborValue.Text(file.name))
                                        put("mime", CborValue.Text(file.mimeType))
                                        put("size", CborValue.UInt(file.size))
                                        file.lastModified?.let { put("modified", CborValue.int(it)) }
                                        put("file", CborValue.Text(file.fileName))
                                    },
                                )
                            },
                        ),
                    )
                },
            ),
        )

        internal fun decode(bytes: ByteArray): QueuedTransfer {
            val map = Cbor.decode(bytes) as? CborValue.Map ?: throw CborException("manifest is not a map")
            if (map.uint("version") != FORMAT_VERSION) throw CborException("unsupported manifest version")
            val files = map.array("files").map { entry ->
                val file = entry as? CborValue.Map ?: throw CborException("file is not a map")
                val fileName = file.text("file")
                // Only names this store wrote: never a path outside the item's directory.
                if (!fileName.matches(Regex("f[0-9]+"))) throw CborException("bad spool file name")
                QueuedFile(
                    name = file.text("name"),
                    mimeType = file.text("mime"),
                    size = file.uint("size"),
                    lastModified = when (val modified = file.entries["modified"]) {
                        is CborValue.UInt -> modified.value
                        is CborValue.NInt -> -1 - modified.n
                        else -> null
                    },
                    fileName = fileName,
                )
            }
            val text = (map.entries["text"] as? CborValue.Text)?.value
            if (text == null && files.isEmpty()) throw CborException("nothing to send")
            return QueuedTransfer(map.text("id"), map.text("deviceId"), map.uint("created"), files, text)
        }
    }
}
