package dev.localdrop.core.transfer

import android.content.ContentResolver
import android.content.ContentValues
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import dev.localdrop.core.protocol.CborException
import dev.localdrop.core.protocol.CborValue
import dev.localdrop.core.protocol.Message
import dev.localdrop.core.protocol.MessageType
import dev.localdrop.core.protocol.array
import dev.localdrop.core.protocol.bytes
import dev.localdrop.core.protocol.text
import dev.localdrop.core.protocol.uint
import java.io.IOException
import java.io.OutputStream

/** One file announced by a Mac (protocol/messages.md, FileInfo). [name] is already sanitized. */
class IncomingFile(val fileId: Int, val name: String, val mimeType: String, val size: Long, val lastModified: Long?)

/** A `transfer_request` from a Mac. */
class IncomingRequest(val transferId: ByteArray, val files: List<IncomingFile>, val totalSize: Long) {
    companion object {
        private const val MAX_FILES = 1000

        /** @throws CborException if the request is malformed. */
        fun parse(message: Message): IncomingRequest {
            if (message.type != MessageType.TRANSFER_REQUEST) throw CborException("expected transfer_request, got ${message.type}")
            val body = CborValue.Map(message.body)
            val transferId = body.bytes("transferId")
            if (transferId.size != 16) throw CborException("transferId must be 16 bytes")
            val entries = body.array("files")
            if (entries.isEmpty() || entries.size > MAX_FILES) throw CborException("a transfer has 1–$MAX_FILES files")
            val files = entries.mapIndexed { index, entry ->
                val file = entry as? CborValue.Map ?: throw CborException("file is not a map")
                if (file.uint("fileId") != index.toLong()) throw CborException("fileId must equal its index")
                IncomingFile(
                    fileId = index,
                    name = FileNames.sanitize(file.text("name")),
                    mimeType = (file.entries["mimeType"] as? CborValue.Text)?.value ?: "application/octet-stream",
                    size = file.uint("size"),
                    lastModified = (file.entries["lastModified"] as? CborValue.UInt)?.value,
                )
            }
            val total = body.uint("totalSize")
            if (total != files.sumOf { it.size }) throw CborException("totalSize does not match files")
            return IncomingRequest(transferId, files, total)
        }
    }
}

/** Names from another device never become paths: no separators, no control characters, bounded length. */
object FileNames {
    private const val MAX_LENGTH = 200

    fun sanitize(raw: String): String {
        val cleaned = raw.substringAfterLast('/').substringAfterLast('\\')
            .filter { it >= ' ' && it != '\u007F' }
            .replace(Regex("[:*?\"<>|]"), "_")
            .trim()
            .trimStart('.')
        val name = cleaned.ifEmpty { "file" }
        if (name.length <= MAX_LENGTH) return name
        val extension = name.substringAfterLast('.', "").take(16)
        val base = name.dropLast(if (extension.isEmpty()) 0 else extension.length + 1)
        return base.take(MAX_LENGTH - extension.length - 1) + if (extension.isEmpty()) "" else ".$extension"
    }
}

/** A received file, saved in Downloads. */
class ReceivedFile(val uri: Uri, val name: String, val mimeType: String, val size: Long)

/**
 * A file being written to Downloads through MediaStore: hidden (`IS_PENDING`) until its SHA-256
 * is verified, deleted if it isn't. No storage permission is needed for files LocalDrop creates.
 */
class DownloadWriter private constructor(
    private val resolver: ContentResolver,
    val uri: Uri,
    private val output: OutputStream,
    private val requestedName: String,
    /** The sender's type, or the one Android knows for the extension when the sender had none. */
    val mimeType: String,
) {
    fun write(data: ByteArray, offset: Int, length: Int) = output.write(data, offset, length)

    /** Makes the verified file visible in Downloads. */
    fun publish() {
        output.close()
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        keepExtensionLast()
    }

    /**
     * MediaStore makes a taken name unique with " (1)", but puts it after the extension when it
     * doesn't know the file type ("data.bin (1)"), and the file no longer opens as what it is.
     */
    private fun keepExtensionLast() {
        val given = displayName(requestedName)
        val dot = requestedName.lastIndexOf('.')
        val counter = UNIQUE_SUFFIX.matchEntire(given.removePrefix(requestedName))?.groupValues?.get(1)?.toIntOrNull()
        if (counter == null || !given.startsWith(requestedName) || dot <= 0) return
        // MediaStore counted "name.ext (n)", which it may not have used before, while
        // "name (n).ext" from an earlier copy can be taken: take the first free number.
        val base = requestedName.substring(0, dot)
        val extension = requestedName.substring(dot)
        val fixed = generateSequence(counter) { it + 1 }.take(MAX_COUNTER)
            .map { "$base ($it)$extension" }
            .firstOrNull { !isTaken(it) } ?: return
        val rows = resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.DISPLAY_NAME, fixed) }, null, null)
        Log.i(TAG, "MediaStore named it \"$given\"; renamed to \"${displayName(fixed)}\" ($rows row)")
    }

    /** Another file in Downloads has [name]. LocalDrop sees its own files, the ones that clash here. */
    private fun isTaken(name: String): Boolean = resolver.query(
        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
        arrayOf(MediaStore.MediaColumns._ID),
        "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
        arrayOf(name, Environment.DIRECTORY_DOWNLOADS + "/"),
        null,
    )?.use { it.count > 0 } ?: false

    /** Removes an incomplete or damaged file. Best effort: called on failure paths. */
    fun discard() {
        try {
            output.close()
        } catch (e: IOException) {
            // Already broken; the row is deleted below either way.
        }
        resolver.delete(uri, null, null)
    }

    /** The name MediaStore gave the file (it adds " (1)" on conflicts). */
    fun displayName(fallback: String): String =
        resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        } ?: fallback

    companion object {
        private const val TAG = "LD/transfer"
        private val UNIQUE_SUFFIX = Regex(" \\((\\d+)\\)")
        private const val MAX_COUNTER = 1000
        private const val UNKNOWN_TYPE = "application/octet-stream"

        /** A Mac sends `application/octet-stream` for types macOS doesn't know, such as .apk. */
        private fun mimeTypeOf(file: IncomingFile): String {
            if (file.mimeType.isNotBlank() && file.mimeType != UNKNOWN_TYPE) return file.mimeType
            val extension = file.name.substringAfterLast('.', "").lowercase()
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: UNKNOWN_TYPE
        }

        @Throws(IOException::class)
        fun create(resolver: ContentResolver, file: IncomingFile): DownloadWriter {
            val mimeType = mimeTypeOf(file)
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("MediaStore refused ${file.name}")
            val output = try {
                resolver.openOutputStream(uri) ?: throw IOException("No output stream for ${file.name}")
            } catch (e: IOException) {
                resolver.delete(uri, null, null)
                throw e
            }
            return DownloadWriter(resolver, uri, output, file.name, mimeType)
        }
    }
}
