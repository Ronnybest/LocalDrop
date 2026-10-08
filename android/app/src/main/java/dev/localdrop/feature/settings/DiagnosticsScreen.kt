package dev.localdrop.feature.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.localdrop.R
import dev.localdrop.core.transfer.TestDataSource
import dev.localdrop.feature.devices.HomeViewModel

/** Generated-data transfers to a paired Mac, for measuring speed and checking integrity. */
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
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.diagnostics_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(vertical = 8.dp)) {
            Text(
                stringResource(R.string.test_data_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
            Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TestDataSource.SIZES.forEach { size ->
                    FilterChip(
                        selected = size == testDataSize,
                        onClick = { onTestDataSizeSelected(size) },
                        label = { Text(TestDataSource.label(size)) },
                    )
                }
            }
            if (devices.isEmpty()) {
                Text(stringResource(R.string.diagnostics_no_devices), modifier = Modifier.padding(16.dp))
            }
            devices.forEach { device ->
                ListItem(
                    modifier = Modifier.clickable { onSendTestData(device.deviceId) },
                    leadingContent = { Icon(painterResource(R.drawable.ic_laptop), contentDescription = null) },
                    headlineContent = { Text(device.deviceName) },
                    supportingContent = { Text(stringResource(R.string.diagnostics_send_to, TestDataSource.label(testDataSize))) },
                )
            }
        }
    }
}
