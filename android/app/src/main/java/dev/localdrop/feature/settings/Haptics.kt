package dev.localdrop.feature.settings

import android.content.Context
import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** What a touch or an outcome feels like. */
enum class Haptic {
    /** A button pressed. */
    TICK,

    /** Done: sent, received, paired, accepted. */
    CONFIRM,

    /** Declined, cancelled, codes differ. */
    REJECT,
    TOGGLE_ON,
    TOGGLE_OFF,

    /** A swipe went far enough to delete. */
    THRESHOLD,
}

/**
 * Haptic feedback for the app's actions, on unless turned off in Settings. It goes through the
 * view, so Android's own "touch feedback" setting still applies on top.
 */
object Haptics {
    private const val PREFS = "settings"
    private const val KEY = "haptics"
    private val enabled = MutableStateFlow<Boolean?>(null)

    fun enabled(context: Context): StateFlow<Boolean?> {
        if (enabled.value == null) enabled.value = prefs(context).getBoolean(KEY, true)
        return enabled.asStateFlow()
    }

    fun setEnabled(context: Context, on: Boolean) {
        prefs(context).edit { putBoolean(KEY, on) }
        enabled.value = on
    }

    fun perform(view: View, haptic: Haptic) {
        if (enabled(view.context).value == false) return
        view.performHapticFeedback(constant(haptic))
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The closest system pattern; newer ones fall back on older Android. */
    private fun constant(haptic: Haptic): Int = when (haptic) {
        Haptic.TICK -> HapticFeedbackConstants.KEYBOARD_TAP
        Haptic.CONFIRM -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.CONTEXT_CLICK
        Haptic.REJECT -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
        Haptic.TOGGLE_ON -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) HapticFeedbackConstants.TOGGLE_ON else HapticFeedbackConstants.CLOCK_TICK
        Haptic.TOGGLE_OFF -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) HapticFeedbackConstants.TOGGLE_OFF else HapticFeedbackConstants.CLOCK_TICK
        Haptic.THRESHOLD ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE else HapticFeedbackConstants.CONTEXT_CLICK
    }
}

/** `val haptic = rememberHaptics(); haptic(Haptic.CONFIRM)` */
@Composable
fun rememberHaptics(): (Haptic) -> Unit {
    val view = LocalView.current
    LocalContext.current.let { Haptics.enabled(it) }
    return remember(view) { { haptic -> Haptics.perform(view, haptic) } }
}
