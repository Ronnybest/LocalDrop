package dev.localdrop.feature.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import dev.localdrop.R
import dev.localdrop.feature.share.ShareTargetActivity

/**
 * Reads the clipboard for the Quick Settings tile and hands it to [ShareTargetActivity] as an
 * ordinary share, so text, copied files and the choice of Mac work exactly like sharing.
 * Invisible; the clipboard is readable only once this window has focus (API 29+).
 */
class ClipboardSendActivity : ComponentActivity() {

    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handled = savedInstanceState?.getBoolean(KEY_HANDLED) ?: false
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_HANDLED, handled)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        handled = true
        val clip = getSystemService(ClipboardManager::class.java).primaryClip
        val share = clip?.let(::shareIntent)
        if (share == null) {
            Log.i(TAG, "Clipboard is empty")
            Toast.makeText(this, R.string.clipboard_empty, Toast.LENGTH_SHORT).show()
        } else {
            startActivity(share)
        }
        finish()
    }

    /** Copied files (content URIs) are sent as files; otherwise the text. Nothing is logged. */
    private fun shareIntent(clip: ClipData): Intent? {
        val items = List(clip.itemCount, clip::getItemAt)
        val uris = items.mapNotNull { it.uri }
        val intent = Intent(this, ShareTargetActivity::class.java)
        if (uris.isNotEmpty()) {
            Log.i(TAG, "Sending ${uris.size} copied item(s)")
            val type = clip.description.takeIf { it.mimeTypeCount == 1 }?.getMimeType(0) ?: "*/*"
            val forward = ClipData.newRawUri(null, uris.first()).apply { uris.drop(1).forEach { addItem(ClipData.Item(it)) } }
            intent.clipData = forward
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            return if (uris.size == 1) {
                intent.setAction(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uris.first())
            } else {
                intent.setAction(Intent.ACTION_SEND_MULTIPLE).setType(type).putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList<Uri>(uris))
            }
        }
        val text = items.mapNotNull { it.text?.toString() }.joinToString("\n").takeIf { it.isNotBlank() } ?: return null
        Log.i(TAG, "Sending copied text")
        return intent.setAction(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
    }

    private companion object {
        const val TAG = "LD/clipboard"
        const val KEY_HANDLED = "handled"
    }
}
