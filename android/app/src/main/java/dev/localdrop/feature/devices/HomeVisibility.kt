package dev.localdrop.feature.devices

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The Mac whose card is on screen right now, if the home screen is in front: that card shows a
 * request from the Mac with its own Accept and Decline. The request's notification then arrives
 * quietly instead of popping up over the card that already asks; leaving home unanswered lets
 * it alert. Other Macs' requests alert as usual.
 */
object HomeVisibility {
    private val _cardMac = MutableStateFlow<String?>(null)
    val cardMac: StateFlow<String?> = _cardMac.asStateFlow()

    internal fun set(deviceId: String?) {
        _cardMac.value = deviceId
        android.util.Log.i("LD/home", "Card on screen: $deviceId")
    }
}
