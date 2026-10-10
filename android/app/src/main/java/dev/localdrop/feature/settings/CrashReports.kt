package dev.localdrop.feature.settings

import android.content.Context
import androidx.core.content.edit
import com.google.firebase.FirebaseApp
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dev.localdrop.BuildConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Crash reports to the developer through Firebase Crashlytics: on by default, off in Settings.
 * The manifest keeps collection off until [apply] decides at start, so nothing is sent from
 * development builds or builds without the owner's Firebase configuration (then [available]
 * is false and Settings has no switch). A report holds the stack trace, device model, Android
 * and app version and a random installation id; the app adds no logs or keys to it.
 */
object CrashReports {
    private const val PREFS = "settings"
    private const val KEY = "crash_reports"
    private val enabled = MutableStateFlow<Boolean?>(null)

    fun available(context: Context): Boolean = BuildConfig.CRASH_REPORTS && FirebaseApp.getApps(context).isNotEmpty()

    fun enabled(context: Context): StateFlow<Boolean?> {
        if (enabled.value == null) enabled.value = prefs(context).getBoolean(KEY, true)
        return enabled.asStateFlow()
    }

    fun setEnabled(context: Context, on: Boolean) {
        prefs(context).edit { putBoolean(KEY, on) }
        enabled.value = on
        apply(context)
    }

    /** At start and after the switch: Crashlytics remembers the choice itself. */
    fun apply(context: Context) {
        if (!available(context)) return
        val on = enabled(context).value != false
        FirebaseCrashlytics.getInstance().isCrashlyticsCollectionEnabled = on
        // Reports kept while off are not sent later.
        if (!on) FirebaseCrashlytics.getInstance().deleteUnsentReports()
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
