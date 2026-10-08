package dev.localdrop.core.transfer

import android.content.ContentResolver
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import dev.localdrop.core.protocol.ProtocolConstants
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Files shared from another app (`content://` URIs from `ACTION_SEND` / `ACTION_SEND_MULTIPLE`)
 * plus optional shared text. Data is streamed from the ContentResolver; nothing is copied, and no
 * file system path is ever derived from a URI.
 *
 * Read access comes from the URI grant of the share intent, which must stay attached to the
 * component doing the transfer (the foreground service).
 */
class ContentUriSource(
    private val resolver: ContentResolver,
    private val uris: List<Uri>,
    private val text: String?,
) : TransferSource {

    override val description: String = when {
        uris.size == 1 -> uris.first().lastPathSegment ?: "file"
        uris.size > 1 -> "${uris.size} files"
        else -> "text"
    }

    override val clipboardText: String?
        get() = text?.takeIf { uris.isEmpty() && it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= ProtocolConstants.MAX_TEXT_SIZE }

    override fun files(): List<SourceFile> {
        val files = uris.map(::describe).toMutableList()
        if (!text.isNullOrEmpty()) files += textSourceFile(text)
        return files
    }

    private fun describe(uri: Uri): SourceFile {
        var name: String? = null
        var size: Long? = null
        var lastModified: Long? = null
        // A null projection returns every column the provider has; providers differ widely.
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                name = cursor.string(OpenableColumns.DISPLAY_NAME)
                size = cursor.long(OpenableColumns.SIZE)?.takeIf { it >= 0 }
                lastModified = cursor.long(DocumentsContract.Document.COLUMN_LAST_MODIFIED)?.takeIf { it > 0 }
            }
        } ?: throw FileNotFoundException("No metadata for shared item")
        val mimeType = resolver.getType(uri) ?: "application/octet-stream"
        val length = size ?: lengthOf(uri)
        return SourceFile(
            name = withExtension(name?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment ?: "file", mimeType),
            mimeType = mimeType,
            size = length,
            lastModified = lastModified,
            open = { resolver.openInputStream(uri) ?: throw FileNotFoundException("Provider returned no stream") },
        )
    }

    /** Size when the provider doesn't report it: the descriptor length, or a counting pass. */
    private fun lengthOf(uri: Uri): Long {
        resolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
            if (descriptor.length != AssetFileDescriptor.UNKNOWN_LENGTH) return descriptor.length
        }
        Log.i(TAG, "Provider reports no size; counting bytes")
        val input = resolver.openInputStream(uri) ?: throw FileNotFoundException("Provider returned no stream")
        return input.use { stream ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val n = stream.read(buffer)
                if (n < 0) break
                total += n
            }
            total
        }
    }

    private fun withExtension(name: String, mimeType: String): String {
        if (name.contains('.')) return name
        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType) ?: return name
        return "$name.$extension"
    }

    private fun Cursor.string(column: String): String? =
        getColumnIndex(column).takeIf { it >= 0 && !isNull(it) }?.let(::getString)

    private fun Cursor.long(column: String): Long? =
        getColumnIndex(column).takeIf { it >= 0 && !isNull(it) }?.let(::getLong)

    private companion object {
        const val TAG = "LD/transfer"
    }
}

