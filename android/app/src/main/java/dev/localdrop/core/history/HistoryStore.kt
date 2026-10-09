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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One finished transfer, for the home screen's "Recent" list. */
class HistoryEntry(
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
) {
    enum class Kind { FILES, TEXT, LINK }
}

/**
 * The last [MAX_ENTRIES] transfers, newest first, on this phone only: never synced, never backed
 * up (noBackupFilesDir). Received texts keep only their first characters, links in full so they
 * can be opened again.
 */
class HistoryStore(private val file: File, private val clock: () -> Long = System::currentTimeMillis) {

    private val _entries = MutableStateFlow<List<HistoryEntry>>(emptyList())
    val entries: StateFlow<List<HistoryEntry>> = _entries.asStateFlow()
    private var loaded = false

    @Synchronized
    fun load() {
        if (loaded) return
        loaded = true
        _entries.value = try {
            decode(AtomicFile(file).readFully())
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
    ) {
        load()
        val stored = if (kind == HistoryEntry.Kind.TEXT) title.trim().take(TEXT_PREVIEW) else title
        val entry = HistoryEntry(clock(), incoming, peerName, kind, stored, count, uri, mimeType)
        val entries = (listOf(entry) + _entries.value).take(MAX_ENTRIES)
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
    }

    internal companion object {
        private const val TAG = "LD/history"
        const val MAX_ENTRIES = 30
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
                                    put("time", CborValue.UInt(entry.timeMs))
                                    put("incoming", CborValue.Bool(entry.incoming))
                                    put("peer", CborValue.Text(entry.peerName))
                                    put("kind", CborValue.Text(entry.kind.name))
                                    put("title", CborValue.Text(entry.title))
                                    put("count", CborValue.UInt(entry.count.toLong()))
                                    entry.uri?.let { put("uri", CborValue.Text(it)) }
                                    entry.mimeType?.let { put("mime", CborValue.Text(it)) }
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
                    timeMs = entry.uint("time"),
                    incoming = entry.bool("incoming"),
                    peerName = entry.text("peer"),
                    kind = kind,
                    title = entry.text("title"),
                    count = entry.uint("count").toInt(),
                    uri = (entry.entries["uri"] as? CborValue.Text)?.value,
                    mimeType = (entry.entries["mime"] as? CborValue.Text)?.value,
                )
            }
        }
    }
}
