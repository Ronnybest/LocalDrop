package dev.localdrop.feature.settings

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Recent shows photos and videos as icons instead of previews, for privacy; off by default. */
object ThumbnailSetting {
    private const val PREFS = "settings"
    private const val KEY = "hide_thumbnails"
    private val hidden = MutableStateFlow<Boolean?>(null)

    fun hidden(context: Context): StateFlow<Boolean?> {
        if (hidden.value == null) hidden.value = prefs(context).getBoolean(KEY, false)
        return hidden.asStateFlow()
    }

    fun setHidden(context: Context, hide: Boolean) {
        prefs(context).edit { putBoolean(KEY, hide) }
        hidden.value = hide
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
