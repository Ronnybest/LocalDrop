package dev.localdrop.feature.devices

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.localdrop.R
import dev.localdrop.core.discovery.DiscoveryState
import dev.localdrop.core.discovery.EndpointFailure
import dev.localdrop.core.discovery.EndpointState
import dev.localdrop.core.discovery.NearbyDevice
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.feature.settings.DiscoveryBlockerCard
import dev.localdrop.feature.settings.MessageCard

/**
 * Pairing a new Mac: the one place a list of nearby devices makes sense. Sending never starts
 * here; after pairing, the Mac is a share target of its own.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddDeviceScreen(
    onPair: (EndpointInfo) -> Unit,
    onBack: () -> Unit,
    viewModel: DevicesViewModel = viewModel(factory = DevicesViewModel.Factory),
) {
    BackHandler(onBack = onBack)
    val state by viewModel.state.collectAsStateWithLifecycle()
    val pairedFingerprints by viewModel.pairedFingerprints.collectAsStateWithLifecycle()

    // Returning from system settings may have changed permissions or location; re-check then.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        if (viewModel.state.value is DiscoveryState.Blocked) viewModel.retry()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.add_mac_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Text(
                stringResource(R.string.add_mac_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
            when (val current = state) {
                null -> Unit
                is DiscoveryState.Blocked -> DiscoveryBlockerCard(current.blocker, viewModel::retry)
                is DiscoveryState.Failed -> MessageCard(
                    title = stringResource(R.string.discovery_failed_title),
                    body = current.message,
                    actionLabel = stringResource(R.string.action_try_again),
                    onAction = viewModel::retry,
                )
                is DiscoveryState.Scanning ->
                    if (current.devices.isEmpty()) Searching() else DeviceList(current.devices, pairedFingerprints, onPair)
            }
        }
    }
}

@Composable
private fun DeviceList(devices: List<NearbyDevice>, pairedFingerprints: Set<String>, onPair: (EndpointInfo) -> Unit) {
    LazyColumn(contentPadding = PaddingValues(vertical = 4.dp)) {
        items(devices, key = { it.key }) { device ->
            val info = (device.endpoint as? EndpointState.Resolved)?.info
            val paired = info?.fingerprint?.toHexString() in pairedFingerprints
            ListItem(
                modifier = if (info != null) Modifier.clickable { onPair(info) } else Modifier,
                leadingContent = {
                    Icon(
                        painterResource(if (info?.platform == "android") R.drawable.ic_phone else R.drawable.ic_laptop),
                        contentDescription = null,
                    )
                },
                headlineContent = { Text(device.displayName) },
                supportingContent = {
                    val (text, isError) = when (val endpoint = device.endpoint) {
                        EndpointState.Resolving -> stringResource(R.string.device_status_connecting) to false
                        is EndpointState.Resolved -> stringResource(
                            if (paired) R.string.device_status_already_paired else R.string.device_status_tap_to_pair,
                        ) to false
                        is EndpointState.AlreadyPaired -> stringResource(R.string.device_status_already_paired) to false
                        is EndpointState.Failed -> stringResource(
                            when (endpoint.reason) {
                                EndpointFailure.Unreachable -> R.string.device_status_unreachable
                                EndpointFailure.InvalidData -> R.string.device_status_invalid
                                EndpointFailure.IncompatibleVersion -> R.string.device_status_incompatible
                            },
                        ) to true
                    }
                    Text(text, color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                },
                trailingContent = {
                    if (device.endpoint == EndpointState.Resolving) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    }
                },
            )
        }
    }
}

@Composable
private fun Searching() {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            CircularProgressIndicator()
            Text(stringResource(R.string.devices_searching), style = MaterialTheme.typography.titleMedium)
            Text(
                stringResource(R.string.devices_searching_hint),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}
