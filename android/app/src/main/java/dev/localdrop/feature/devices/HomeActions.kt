package dev.localdrop.feature.devices

import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.widget.Toast
import dev.localdrop.R
import dev.localdrop.core.history.HistoryEntry
import dev.localdrop.feature.transfer.TransferService
import dev.localdrop.feature.transfer.webLink

/** The main Mac card's buttons: files picked in the system picker, or what is on the clipboard. */
internal object SendFromHome {
    fun files(context: Context, deviceId: String, uris: List<Uri>) {
        Log.i(TAG, "Sending ${uris.size} picked file(s)")
        TransferService.sendShared(context, deviceId, uris, null)
    }

    /**
     * Copied files go as files, otherwise the text: the same as the Quick Settings tile. The app
     * is in front, so it may read the clipboard. Nothing copied is logged.
     */
    fun clipboard(context: Context, deviceId: String) {
        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip
        val items = clip?.let { List(it.itemCount, it::getItemAt) }.orEmpty()
        val uris = items.mapNotNull { it.uri }
        val text = items.mapNotNull { it.text?.toString() }.joinToString("\n").takeIf { it.isNotBlank() }
        if (uris.isEmpty() && text == null) {
            Toast.makeText(context, R.string.clipboard_empty, Toast.LENGTH_SHORT).show()
            return
        }
        Log.i(TAG, if (uris.isNotEmpty()) "Sending ${uris.size} copied item(s)" else "Sending copied text")
        TransferService.sendShared(context, deviceId, uris, text.takeIf { uris.isEmpty() })
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

    private fun openFile(context: Context, entry: HistoryEntry) {
        val uri = entry.uri?.let(Uri::parse)
        val isApp = entry.mimeType == APK_MIME_TYPE || entry.title.endsWith(".apk", ignoreCase = true)
        // Several files, or an app to install (Files installs it from Downloads): the Downloads list.
        if (uri == null || isApp) {
            start(context, Intent(DownloadManager.ACTION_VIEW_DOWNLOADS))
            return
        }
        if (!exists(context, uri)) {
            Toast.makeText(context, R.string.history_file_gone, Toast.LENGTH_SHORT).show()
            return
        }
        start(context, Intent(Intent.ACTION_VIEW).setDataAndType(uri, entry.mimeType).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    }

    /** Deleted in Files since: MediaStore no longer has it. */
    private fun exists(context: Context, uri: Uri): Boolean = try {
        context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)?.use { it.moveToFirst() } == true
    } catch (e: SecurityException) {
        false
    } catch (e: IllegalArgumentException) {
        false
    }

    private fun start(context: Context, intent: Intent) {
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(context, R.string.history_file_gone, Toast.LENGTH_SHORT).show()
        }
    }

    private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
}
