package dev.localdrop.core.history

import android.util.Log
import androidx.core.util.AtomicFile
import dev.localdrop.core.protocol.Cbor
import dev.localdrop.core.protocol.CborException
import dev.localdrop.core.protocol.CborValue
import dev.localdrop.core.protocol.array
import dev.localdrop.core.protocol.bool
import dev.localdrop.core.protocol.text
import dev.localdrop.core.protocol.uint
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One finished transfer, for the home screen's "Recent" list. */
class HistoryEntry(
    val id: String,
    val timeMs: Long,
    /** True for what came from the Mac, false for what this phone sent. */
    val incoming: Boolean,
    val peerName: String,
    val kind: Kind,
    /** A file's name, "3 files" is made from [count]; a link or the start of a text. */
    val title: String,
    val count: Int = 1,
    /** A single received file, opened from the list; null when there is nothing to open. */
    val uri: String? = null,
    val mimeType: String? = null,
    /** Files' total size; known for files. */
    val bytes: Long? = null,
    /** How long a send took; known for files this phone sent. */
    val durationMs: Long? = null,
    /** The folder of the file on this phone, relative to its storage ("Download", "DCIM/Camera"); when known. */
    val folder: String? = null,
) {
    enum class Kind { FILES, TEXT, LINK }
}

/**
 * Transfers of the last [MAX_AGE_MS] (30 days), newest first, on this phone only: never synced,
 * never backed up (noBackupFilesDir). Received texts keep only their first characters, links in
 * full so they can be opened again. The user can delete any entry.
 */
class HistoryStore(
    private val file: File,
    private val clock: () -> Long = System::currentTimeMillis,
    /** Entries gone from the history (deleted or expired): read access kept for them can go. */
    private val onDropped: (List<HistoryEntry>) -> Unit = {},
) {

    private val _entries = MutableStateFlow<List<HistoryEntry>>(emptyList())
    val entries: StateFlow<List<HistoryEntry>> = _entries.asStateFlow()
    private var loaded = false

    @Synchronized
    fun load() {
        if (loaded) return
        loaded = true
        _entries.value = try {
            val all = decode(AtomicFile(file).readFully())
            fresh(all).also { kept -> all.filter { it !in kept }.takeIf { it.isNotEmpty() }?.let(onDropped) }
        } catch (e: FileNotFoundException) {
            emptyList()
        } catch (e: IOException) {
            Log.w(TAG, "Unreadable history: ${e.message}")
            emptyList()
        } catch (e: CborException) {
            Log.w(TAG, "Corrupt history, starting over: ${e.message}")
            emptyList()
        }
    }

    @Synchronized
    fun add(
        incoming: Boolean,
        peerName: String,
        kind: HistoryEntry.Kind,
        title: String,
        count: Int = 1,
        uri: String? = null,
        mimeType: String? = null,
        bytes: Long? = null,
        durationMs: Long? = null,
        folder: String? = null,
    ) {
        load()
        val stored = if (kind == HistoryEntry.Kind.TEXT) title.trim().take(TEXT_PREVIEW) else title
        val entry = HistoryEntry(UUID.randomUUID().toString(), clock(), incoming, peerName, kind, stored, count, uri, mimeType, bytes, durationMs, folder)
        save(fresh(listOf(entry) + _entries.value))
    }

    @Synchronized
    fun remove(id: String) {
        load()
        save(_entries.value.filterNot { it.id == id })
    }

    /** Within [MAX_AGE_MS], and at most [MAX_ENTRIES] so the file stays small. */
    private fun fresh(entries: List<HistoryEntry>): List<HistoryEntry> {
        val oldest = clock() - MAX_AGE_MS
        return entries.filter { it.timeMs >= oldest }.take(MAX_ENTRIES)
    }

    private fun save(entries: List<HistoryEntry>) {
        val kept = entries.mapTo(HashSet()) { it.id }
        val dropped = _entries.value.filter { it.id !in kept }
        try {
            val atomic = AtomicFile(file)
            val out = atomic.startWrite()
            try {
                out.write(encode(entries))
                atomic.finishWrite(out)
            } catch (e: IOException) {
                atomic.failWrite(out)
                throw e
            }
        } catch (e: IOException) {
            Log.e(TAG, "Could not save history", e)
        }
        _entries.value = entries
        if (dropped.isNotEmpty()) onDropped(dropped)
    }

    internal companion object {
        private const val TAG = "LD/history"
        const val MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000
        const val MAX_ENTRIES = 500
        private const val TEXT_PREVIEW = 120
        private const val FORMAT_VERSION = 1L

        fun encode(entries: List<HistoryEntry>): ByteArray = Cbor.encode(
            CborValue.Map(
                mapOf(
                    "version" to CborValue.UInt(FORMAT_VERSION),
                    "entries" to CborValue.Array(
                        entries.map { entry ->
                            CborValue.Map(
                                buildMap {
                                    put("id", CborValue.Text(entry.id))
                                    put("time", CborValue.UInt(entry.timeMs))
                                    put("incoming", CborValue.Bool(entry.incoming))
                                    put("peer", CborValue.Text(entry.peerName))
                                    put("kind", CborValue.Text(entry.kind.name))
                                    put("title", CborValue.Text(entry.title))
                                    put("count", CborValue.UInt(entry.count.toLong()))
                                    entry.uri?.let { put("uri", CborValue.Text(it)) }
                                    entry.mimeType?.let { put("mime", CborValue.Text(it)) }
                                    entry.bytes?.let { put("bytes", CborValue.UInt(it)) }
                                    entry.durationMs?.let { put("duration", CborValue.UInt(it)) }
                                    entry.folder?.let { put("folder", CborValue.Text(it)) }
                                },
                            )
                        },
                    ),
                ),
            ),
        )

        fun decode(bytes: ByteArray): List<HistoryEntry> {
            val map = Cbor.decode(bytes) as? CborValue.Map ?: throw CborException("history is not a map")
            if (map.uint("version") != FORMAT_VERSION) throw CborException("unsupported history version")
            return map.array("entries").mapNotNull { value ->
                val entry = value as? CborValue.Map ?: throw CborException("entry is not a map")
                val kind = HistoryEntry.Kind.entries.firstOrNull { it.name == entry.text("kind") } ?: return@mapNotNull null
                HistoryEntry(
                    // Entries saved before ids existed get one now.
                    id = (entry.entries["id"] as? CborValue.Text)?.value ?: UUID.randomUUID().toString(),
                    timeMs = entry.uint("time"),
                    incoming = entry.bool("incoming"),
                    peerName = entry.text("peer"),
                    kind = kind,
                    title = entry.text("title"),
                    count = entry.uint("count").toInt(),
                    uri = (entry.entries["uri"] as? CborValue.Text)?.value,
                    mimeType = (entry.entries["mime"] as? CborValue.Text)?.value,
                    bytes = (entry.entries["bytes"] as? CborValue.UInt)?.value,
                    durationMs = (entry.entries["duration"] as? CborValue.UInt)?.value,
                    folder = (entry.entries["folder"] as? CborValue.Text)?.value,
                )
            }
        }
    }
}
