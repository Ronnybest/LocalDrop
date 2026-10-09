package dev.localdrop.feature.devices

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.clickable
import dev.localdrop.R
import dev.localdrop.core.device.TrustedDevice

/**
 * A Mac's settings, rarely changed: which Mac is the main one, how files from it are received,
 * its key to compare with the Mac, and forgetting it.
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
        Column(Modifier.navigationBarsPadding().padding(bottom = 8.dp)) {
            Row(
                Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                RoundIcon(size = 48, tint = MaterialTheme.colorScheme.primaryContainer) {
                    Icon(painterResource(R.drawable.ic_laptop), null, tint = MaterialTheme.colorScheme.onPrimaryContainer)
                }
                Column {
                    Text(device.deviceName, style = MaterialTheme.typography.titleLarge)
                    Text(
                        stringResource(R.string.trusted_last_seen, relativeTime(device.lastSeenMs)),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            val transparent = ListItemDefaults.colors(containerColor = Color.Transparent)
            if (canBeMain) {
                // The main Mac is changed by choosing another one, not by switching this one off.
                SwitchRow(stringResource(R.string.sheet_main_mac), device.isDefault, enabled = !device.isDefault) { onMakeMain() }
            }
            if (device.canSend) {
                SwitchRow(stringResource(R.string.action_receive_automatically), device.receiveAutomatically, onChange = onReceiveAutomatically)
                SwitchRow(stringResource(R.string.action_receive_in_background), linked, onChange = onReceiveInBackground)
            }
            if (verificationCode != null) {
                ListItem(
                    overlineContent = { Text(stringResource(R.string.sheet_verification_code)) },
                    headlineContent = {
                        Text(verificationCode, style = MaterialTheme.typography.titleLarge.copy(fontFeatureSettings = "tnum"))
                    },
                    supportingContent = { Text(stringResource(R.string.sheet_verification_hint)) },
                    colors = transparent,
                    modifier = Modifier.padding(horizontal = 8.dp),
                )
            }
            HorizontalDivider(Modifier.padding(horizontal = 24.dp, vertical = 4.dp))
            ListItem(
                headlineContent = { Text(stringResource(R.string.action_forget), color = MaterialTheme.colorScheme.error) },
                leadingContent = { Icon(Icons.Default.Delete, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.error) },
                colors = transparent,
                modifier = Modifier.padding(horizontal = 8.dp).clickable(onClick = onForget),
            )
        }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = { Switch(checked = checked, onCheckedChange = null, enabled = enabled) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.padding(horizontal = 8.dp).clickable(enabled = enabled) { onChange(!checked) },
    )
}
