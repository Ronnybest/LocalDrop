package dev.localdrop.feature.settings

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.edit

/**
 * Notifications carry a transfer's progress, its result, and Accept for files from a Mac when
 * the app isn't open. Asked for right after pairing, when that is clear, and from Home while
 * they stay off. The system dialog can be shown twice at most; after that, only the app's
 * notification settings can turn them on.
 */
object NotificationAccess {
    private const val PREFS = "share"
    private const val KEY_ASKED = "asked_notifications"

    fun enabled(context: Context): Boolean = NotificationManagerCompat.from(context).areNotificationsEnabled()

    /** Asked once already: the share sheet asks only the first time it is used. */
    fun asked(context: Context): Boolean = prefs(context).getBoolean(KEY_ASKED, false)

    fun markAsked(context: Context) = prefs(context).edit { putBoolean(KEY_ASKED, true) }

    /**
     * The system dialog would still appear: never asked, or refused once (Android then shows a
     * rationale and allows one more ask). Before Android 13 there is no dialog at all.
     */
    fun canAsk(activity: Activity): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            (!asked(activity) || activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))

    fun settingsIntent(context: Context): Intent =
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/**
 * Turns notifications on the way that still works: the system dialog while it may be shown,
 * otherwise the app's notification settings. [onResult] gets whether they are on after the
 * dialog; after the settings, the caller re-checks when the screen resumes.
 */
@Composable
fun rememberNotificationRequest(onResult: (Boolean) -> Unit = {}): () -> Unit {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> onResult(granted) }
    return remember(context, launcher) {
        {
            val activity = context.findActivity()
            if (activity != null && NotificationAccess.canAsk(activity)) {
                NotificationAccess.markAsked(context)
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                context.startActivity(NotificationAccess.settingsIntent(context))
            }
        }
    }
}

private fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
