package dev.localdrop.core.history

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore

/**
 * Where a file lives on this phone, as a folder relative to its shared storage ("Download",
 * "DCIM/Camera"), so the history can open that folder in Files later. Read while LocalDrop still
 * has access to the file (during the send); null when the source doesn't say.
 */
object FileLocation {
    private const val EXTERNAL_STORAGE = "com.android.externalstorage.documents"
    private const val DOWNLOADS = "com.android.providers.downloads.documents"
    private const val MEDIA_DOCUMENTS = "com.android.providers.media.documents"

    fun folderOf(context: Context, uri: Uri): String? = try {
        when {
            uri.authority == EXTERNAL_STORAGE && DocumentsContract.isDocumentUri(context, uri) ->
                DocumentsContract.getDocumentId(uri)
                    .takeIf { it.startsWith("primary:") }
                    ?.substringAfter(':')?.substringBeforeLast('/', "")
                    ?.takeIf { it.isNotEmpty() }
            uri.authority == DOWNLOADS -> Environment.DIRECTORY_DOWNLOADS
            uri.authority == MediaStore.AUTHORITY -> relativePath(context.contentResolver, uri)
            uri.authority == MEDIA_DOCUMENTS -> MediaStore.getMediaUri(context, uri)?.let { relativePath(context.contentResolver, it) }
            else -> null
        }
    } catch (e: SecurityException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    }

    private fun relativePath(resolver: ContentResolver, uri: Uri): String? =
        resolver.query(uri, arrayOf(MediaStore.MediaColumns.RELATIVE_PATH), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0)?.trimEnd('/') else null
        }
}
