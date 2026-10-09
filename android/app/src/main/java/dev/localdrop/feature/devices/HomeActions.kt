package dev.localdrop.feature.devices

import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import android.widget.Toast
import dev.localdrop.R
import dev.localdrop.core.history.HistoryEntry
import dev.localdrop.feature.history.FileKind
import dev.localdrop.feature.transfer.TransferService
import dev.localdrop.feature.transfer.webLink

/** The main Mac card's buttons: files picked in the system picker, or what is on the clipboard. */
internal object SendFromHome {
    fun files(context: Context, deviceId: String, uris: List<Uri>) {
        Log.i(TAG, "Sending ${uris.size} picked file(s)")
        // Kept so Recent can still check and open them; released when they leave the history.
        uris.forEach { uri ->
            try {
                context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (e: SecurityException) {
                Log.w(TAG, "Picked file without persistable access")
            }
        }
        TransferService.sendShared(context, deviceId, uris, null)
    }

    /**
     * Copied files go as files, otherwise the text: the same as the Quick Settings tile. The app
     * is in front, so it may read the clipboard. Nothing copied is logged.
     */
    enum class Clipboard { EMPTY, TEXT, FILES }

    fun clipboard(context: Context, deviceId: String): Clipboard {
        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip
        val items = clip?.let { List(it.itemCount, it::getItemAt) }.orEmpty()
        val uris = items.mapNotNull { it.uri }
        val text = items.mapNotNull { it.text?.toString() }.joinToString("\n").takeIf { it.isNotBlank() }
        if (uris.isEmpty() && text == null) {
            Toast.makeText(context, R.string.clipboard_empty, Toast.LENGTH_SHORT).show()
            return Clipboard.EMPTY
        }
        Log.i(TAG, if (uris.isNotEmpty()) "Sending ${uris.size} copied item(s)" else "Sending copied text")
        TransferService.sendShared(context, deviceId, uris, text.takeIf { uris.isEmpty() })
        return if (uris.isEmpty()) Clipboard.TEXT else Clipboard.FILES
    }

    private const val TAG = "LD/home"
}

/** What tapping a recent transfer does: open the file or the link, copy the text again. */
internal object HistoryActions {
    fun open(context: Context, entry: HistoryEntry) {
        when (entry.kind) {
            HistoryEntry.Kind.LINK -> webLink(entry.title)?.let { start(context, Intent(Intent.ACTION_VIEW, it)) }
            HistoryEntry.Kind.TEXT -> {
                context.getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText(context.getString(R.string.app_name), entry.title))
                // Android 13+ confirms copying itself.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    Toast.makeText(context, R.string.history_copied, Toast.LENGTH_SHORT).show()
                }
            }
            HistoryEntry.Kind.FILES -> openFile(context, entry)
        }
    }

    /**
     * A file is opened only if it is still there. Photos and videos open in the gallery; anything
     * else, or a file LocalDrop can no longer read (a share's access ends with the send), opens
     * its folder in Files — Downloads for received files, where it came from for sent ones.
     */
    private fun openFile(context: Context, entry: HistoryEntry) {
        val kind = FileKind.of(entry)
        val uri = entry.uri?.let(Uri::parse)
        val folder = entry.folder ?: Environment.DIRECTORY_DOWNLOADS.takeIf { entry.incoming }
        val presence = uri?.let { presence(context, it) } ?: Presence.UNKNOWN
        if (presence == Presence.GONE) {
            Toast.makeText(context, R.string.history_file_gone, Toast.LENGTH_SHORT).show()
            return
        }
        if (kind.isVisual && presence == Presence.PRESENT && uri != null) {
            view(context, uri, entry.mimeType)
            return
        }
        if (folder != null && openFolder(context, folder)) return
        if (presence == Presence.PRESENT && uri != null) {
            view(context, uri, entry.mimeType)
            return
        }
        Toast.makeText(context, R.string.history_no_access, Toast.LENGTH_SHORT).show()
    }

    private enum class Presence { PRESENT, GONE, UNKNOWN }

    /** Still there, deleted, or not ours to read any more (then only its folder can be shown). */
    private fun presence(context: Context, uri: Uri): Presence = try {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) Presence.PRESENT else Presence.GONE }
            ?: Presence.GONE
    } catch (e: SecurityException) {
        Presence.UNKNOWN
    } catch (e: IllegalArgumentException) {
        Presence.GONE
    } catch (e: UnsupportedOperationException) {
        Presence.UNKNOWN
    }

    private fun view(context: Context, uri: Uri, mimeType: String?) {
        val type = mimeType ?: context.contentResolver.getType(uri)
        start(context, Intent(Intent.ACTION_VIEW).setDataAndType(uri, type).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    }

    /** Files at [folder] of the shared storage; Downloads falls back to the system Downloads list. */
    private fun openFolder(context: Context, folder: String): Boolean {
        val directory = DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE, "primary:" + folder.trim('/'))
        return try {
            context.startActivity(
                Intent(Intent.ACTION_VIEW).setDataAndType(directory, DocumentsContract.Document.MIME_TYPE_DIR).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (e: ActivityNotFoundException) {
            if (folder == Environment.DIRECTORY_DOWNLOADS) {
                start(context, Intent(DownloadManager.ACTION_VIEW_DOWNLOADS))
                true
            } else {
                false
            }
        }
    }

    private fun start(context: Context, intent: Intent) {
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(context, R.string.history_file_gone, Toast.LENGTH_SHORT).show()
        }
    }

    private const val EXTERNAL_STORAGE = "com.android.externalstorage.documents"
}
