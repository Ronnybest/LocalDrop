package dev.localdrop.feature.devices

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedListItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.localdrop.R
import dev.localdrop.app.ui.Segments
import dev.localdrop.app.ui.segmentColors
import dev.localdrop.app.ui.segmentShape
import dev.localdrop.app.ui.segmentShapes
import dev.localdrop.core.device.TrustedDevice

private class Toggle(val label: Int, val detail: Int, val checked: Boolean, val enabled: Boolean, val onChange: (Boolean) -> Unit)

/**
 * A Mac's settings, rarely changed: which Mac is the main one and how files from it are received
 * (one segmented group), the pair's verification code, and forgetting it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MacSheet(
    device: TrustedDevice,
    /** With one Mac it is the main one anyway. */
    canBeMain: Boolean,
    /** Shown by LocalDrop on the Mac too; null until this phone's key is read. */
    verificationCode: String?,
    linked: Boolean,
    onDismiss: () -> Unit,
    onMakeMain: () -> Unit,
    onReceiveAutomatically: (Boolean) -> Unit,
    onReceiveInBackground: (Boolean) -> Unit,
    onForget: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.navigationBarsPadding().padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            MacAvatar(AvatarState.IDLE, size = 72.dp)
            Spacer(Modifier.height(12.dp))
            Text(device.deviceName, style = MaterialTheme.typography.headlineSmallEmphasized, textAlign = TextAlign.Center)
            Text(
                stringResource(R.string.trusted_last_seen, relativeTime(device.lastSeenMs)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(20.dp))

            val toggles = buildList {
                // The main Mac is changed by choosing another one, not by switching this one off.
                if (canBeMain) add(Toggle(R.string.sheet_main_mac, R.string.sheet_main_mac_body, device.isDefault, !device.isDefault) { onMakeMain() })
                if (device.canSend) {
                    add(Toggle(R.string.action_receive_automatically, R.string.sheet_auto_body, device.receiveAutomatically, true, onReceiveAutomatically))
                    add(Toggle(R.string.action_receive_in_background, R.string.sheet_background_body, linked, true, onReceiveInBackground))
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(Segments.Gap)) {
                toggles.forEachIndexed { index, toggle ->
                    // A plain row that flips its switch: only the switch changes, not the row's color.
                    SegmentedListItem(
                        onClick = { toggle.onChange(!toggle.checked) },
                        shapes = segmentShapes(segmentShape(index, toggles.size)),
                        colors = segmentColors(),
                        enabled = toggle.enabled,
                        supportingContent = { Text(stringResource(toggle.detail)) },
                        trailingContent = { Switch(checked = toggle.checked, onCheckedChange = null, enabled = toggle.enabled) },
                        content = { Text(stringResource(toggle.label)) },
                    )
                }
            }

            if (verificationCode != null) {
                Spacer(Modifier.height(12.dp))
                Surface(
                    shape = RoundedCornerShape(Segments.Outer),
                    color = MaterialTheme.colorScheme.secondaryContainer,
                    contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(stringResource(R.string.sheet_verification_code), style = MaterialTheme.typography.labelLarge)
                        Text(
                            verificationCode,
                            style = MaterialTheme.typography.headlineMediumEmphasized.copy(fontFeatureSettings = "tnum"),
                        )
                        Text(stringResource(R.string.sheet_verification_hint), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }

            Spacer(Modifier.height(20.dp))
            Button(
                onClick = onForget,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer,
                ),
                contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
            ) {
                Icon(Icons.Default.Delete, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
                Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                Text(stringResource(R.string.trusted_forget_button))
            }
        }
    }
}
