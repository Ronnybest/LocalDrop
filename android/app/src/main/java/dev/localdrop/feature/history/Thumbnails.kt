package dev.localdrop.feature.history

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.util.LruCache
import android.util.Size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.compose.ui.platform.LocalContext
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Small previews of photos and videos in the history, from the system's thumbnails. Kept in
 * memory so scrolling doesn't load them again; a file that is gone or no longer readable has none.
 */
object Thumbnails {
    private const val SIZE_PX = 160
    private val cache = object : LruCache<String, Bitmap>(8 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }
    private val missing = HashSet<String>()

    fun cached(uri: String): Bitmap? = cache.get(uri)

    suspend fun load(context: Context, uri: String): Bitmap? {
        cache.get(uri)?.let { return it }
        synchronized(missing) { if (uri in missing) return null }
        val bitmap = withContext(Dispatchers.IO) {
            try {
                context.contentResolver.loadThumbnail(Uri.parse(uri), Size(SIZE_PX, SIZE_PX), null)
            } catch (e: IOException) {
                null
            } catch (e: SecurityException) {
                null
            } catch (e: IllegalArgumentException) {
                null
            }
        }
        if (bitmap != null) cache.put(uri, bitmap) else synchronized(missing) { missing += uri }
        return bitmap
    }
}

/** The preview for [uri], null until loaded or when there is none. */
@Composable
fun rememberThumbnail(uri: String?): State<Bitmap?> {
    val context = LocalContext.current
    return produceState(initialValue = uri?.let(Thumbnails::cached), uri) {
        value = uri?.let { Thumbnails.load(context, it) }
    }
}
