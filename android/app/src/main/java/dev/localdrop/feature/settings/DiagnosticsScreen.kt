package dev.localdrop.feature.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ButtonGroupDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedListItem
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.ToggleButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.localdrop.R
import dev.localdrop.app.ui.Segments
import dev.localdrop.app.ui.segmentColors
import dev.localdrop.app.ui.segmentShape
import dev.localdrop.app.ui.segmentShapes
import dev.localdrop.core.transfer.TestDataSource
import dev.localdrop.feature.devices.AvatarState
import dev.localdrop.feature.devices.HomeViewModel
import dev.localdrop.feature.devices.MacAvatar

/**
 * Settings: haptics on or off; and diagnostics — generated-data transfers to a paired Mac, for
 * measuring speed and checking integrity.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiagnosticsScreen(
    testDataSize: Long,
    onTestDataSizeSelected: (Long) -> Unit,
    onSendTestData: (deviceId: String) -> Unit,
    onBack: () -> Unit,
    viewModel: HomeViewModel = viewModel(factory = HomeViewModel.Factory),
) {
    BackHandler(onBack = onBack)
    val devices by viewModel.devices.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val hapticsOn by Haptics.enabled(context).collectAsStateWithLifecycle()
    val haptic = rememberHaptics()
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text(stringResource(R.string.settings_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
                scrollBehavior = scroll,
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(Segments.Gap),
        ) {
            item(key = "general") { Section(stringResource(R.string.settings_general)) }
            item(key = "haptics") {
                val on = hapticsOn != false
                SegmentedListItem(
                    onClick = {
                        Haptics.setEnabled(context, !on)
                        // Felt only when turning it on: off means off.
                        if (!on) haptic(Haptic.TOGGLE_ON)
                    },
                    shapes = segmentShapes(segmentShape(0, 1)),
                    colors = segmentColors(),
                    supportingContent = { Text(stringResource(R.string.settings_haptics_body)) },
                    trailingContent = { Switch(checked = on, onCheckedChange = null) },
                    content = { Text(stringResource(R.string.settings_haptics)) },
                )
            }

            item(key = "diagnostics") { Section(stringResource(R.string.diagnostics_title)) }
            item(key = "about") {
                Text(
                    stringResource(R.string.test_data_body),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
                )
            }
            item(key = "sizes") {
                // One choice of three: connected toggle buttons, the chosen one rounder.
                val sizes = TestDataSource.SIZES
                Row(
                    Modifier.fillMaxWidth().padding(bottom = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(ButtonGroupDefaults.ConnectedSpaceBetween),
                ) {
                    sizes.forEachIndexed { index, size ->
                        ToggleButton(
                            checked = size == testDataSize,
                            onCheckedChange = {
                                haptic(Haptic.TICK)
                                onTestDataSizeSelected(size)
                            },
                            shapes = when (index) {
                                0 -> ButtonGroupDefaults.connectedLeadingButtonShapes()
                                sizes.lastIndex -> ButtonGroupDefaults.connectedTrailingButtonShapes()
                                else -> ButtonGroupDefaults.connectedMiddleButtonShapes()
                            },
                            modifier = Modifier.weight(1f),
                        ) { Text(TestDataSource.label(size)) }
                    }
                }
            }
            if (devices.isEmpty()) {
                item(key = "none") {
                    Text(stringResource(R.string.diagnostics_no_devices), modifier = Modifier.padding(12.dp))
                }
            }
            itemsIndexed(devices, key = { _, device -> device.deviceId }) { index, device ->
                SegmentedListItem(
                    onClick = {
                        haptic(Haptic.TICK)
                        onSendTestData(device.deviceId)
                    },
                    shapes = segmentShapes(segmentShape(index, devices.size)),
                    colors = segmentColors(),
                    leadingContent = { MacAvatar(AvatarState.IDLE, size = 40.dp) },
                    supportingContent = { Text(stringResource(R.string.diagnostics_send_to, TestDataSource.label(testDataSize))) },
                    modifier = Modifier.animateItem(),
                    content = { Text(device.deviceName) },
                )
            }
        }
    }
}

@Composable
private fun Section(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 12.dp, top = 22.dp, bottom = 10.dp),
    )
}
