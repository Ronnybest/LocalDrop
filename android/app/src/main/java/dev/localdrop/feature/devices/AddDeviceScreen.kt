package dev.localdrop.feature.devices

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.localdrop.R
import dev.localdrop.app.ui.CenteredColumn
import dev.localdrop.core.discovery.DiscoveryState
import dev.localdrop.core.discovery.EndpointFailure
import dev.localdrop.core.discovery.EndpointState
import dev.localdrop.core.discovery.NearbyDevice
import dev.localdrop.core.protocol.EndpointInfo
import dev.localdrop.feature.settings.DiscoveryBlockerCard
import dev.localdrop.feature.settings.MessageCard
import dev.localdrop.feature.settings.Haptic
import dev.localdrop.feature.settings.rememberHaptics

/**
 * Pairing a new Mac: the one place a list of nearby devices makes sense. Sending never starts
 * here; after pairing, the Mac is a share target of its own. While nothing is found, the
 * expressive loading indicator and what to do on the Mac; then each Mac as a card to pair.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddDeviceScreen(
    onPair: (EndpointInfo) -> Unit,
    onBack: () -> Unit,
    viewModel: DevicesViewModel = viewModel(factory = DevicesViewModel.Factory),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val pairedFingerprints by viewModel.pairedFingerprints.collectAsStateWithLifecycle()

    // Returning from system settings may have changed permissions or location; re-check then.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        if (viewModel.state.value is DiscoveryState.Blocked) viewModel.retry()
    }

    Scaffold(
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text(stringResource(R.string.add_mac_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
            )
        },
    ) { padding ->
        // Searching, found, blocked: each fades into the next.
        AnimatedContent(
            targetState = state,
            contentKey = { current ->
                when (current) {
                    is DiscoveryState.Scanning -> if (current.devices.isEmpty()) "searching" else "found"
                    else -> current?.let { it::class.simpleName } ?: "none"
                }
            },
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            modifier = Modifier.fillMaxSize().padding(padding),
            label = "discovery",
        ) { current ->
            when (current) {
                null -> Unit
                is DiscoveryState.Blocked -> Column { DiscoveryBlockerCard(current.blocker, viewModel::retry) }
                is DiscoveryState.Failed -> Column {
                    MessageCard(
                        title = stringResource(R.string.discovery_failed_title),
                        body = current.message,
                        actionLabel = stringResource(R.string.action_try_again),
                        onAction = viewModel::retry,
                    )
                }
                is DiscoveryState.Scanning ->
                    if (current.devices.isEmpty()) Searching() else Found(current.devices, pairedFingerprints, onPair)
            }
        }
    }
}

@Composable
private fun Searching() {
    CenteredColumn(contentPadding = PaddingValues(horizontal = 24.dp, vertical = 16.dp), spacing = 20.dp) {
        LoadingIndicator(Modifier.size(120.dp))
        Text(stringResource(R.string.devices_searching), style = MaterialTheme.typography.titleLargeEmphasized, textAlign = TextAlign.Center)
        Card(
            shape = RoundedCornerShape(28.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Step(1, stringResource(R.string.add_mac_step_menu))
                Step(2, stringResource(R.string.add_mac_step_visible))
                Step(3, stringResource(R.string.add_mac_step_nearby))
            }
        }
    }
}

@Composable
private fun Step(number: Int, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Surface(shape = CircleShape, color = MaterialTheme.colorScheme.primaryContainer, modifier = Modifier.size(28.dp)) {
            Box(contentAlignment = Alignment.Center) {
                Text("$number", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onPrimaryContainer)
            }
        }
        Text(text, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun Found(devices: List<NearbyDevice>, pairedFingerprints: Set<String>, onPair: (EndpointInfo) -> Unit) {
    LazyColumn(
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(devices, key = { it.key }) { device ->
            NearbyMacCard(device, pairedFingerprints, onPair, Modifier.animateItem())
        }
        item(key = "still") {
            Row(
                Modifier.animateItem().fillMaxWidth().padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                LoadingIndicator(Modifier.size(32.dp))
                Text(
                    stringResource(R.string.add_mac_still_searching),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** A Mac nearby: ready to pair (with the button), already paired (dimmed), or why it can't be. */
@Composable
private fun NearbyMacCard(device: NearbyDevice, pairedFingerprints: Set<String>, onPair: (EndpointInfo) -> Unit, modifier: Modifier) {
    val info = (device.endpoint as? EndpointState.Resolved)?.info
    val paired = device.endpoint is EndpointState.AlreadyPaired || info?.fingerprint?.toHexString() in pairedFingerprints
    val (status, isError) = when (val endpoint = device.endpoint) {
        EndpointState.Resolving -> stringResource(R.string.device_status_connecting) to false
        is EndpointState.Resolved -> stringResource(if (paired) R.string.device_status_already_paired else R.string.add_mac_ready) to false
        is EndpointState.AlreadyPaired -> stringResource(R.string.device_status_already_paired) to false
        is EndpointState.Failed -> stringResource(
            when (endpoint.reason) {
                EndpointFailure.Unreachable -> R.string.device_status_unreachable
                EndpointFailure.InvalidData -> R.string.device_status_invalid
                EndpointFailure.IncompatibleVersion -> R.string.device_status_incompatible
            },
        ) to true
    }
    Card(
        shape = RoundedCornerShape(28.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        modifier = modifier.alpha(if (paired) 0.6f else 1f),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                MacAvatar(if (device.endpoint == EndpointState.Resolving) AvatarState.BUSY else AvatarState.IDLE, size = 48.dp)
                Column(Modifier.weight(1f)) {
                    Text(device.displayName, style = MaterialTheme.typography.titleMediumEmphasized)
                    Text(
                        status,
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (info != null && !paired) {
                val haptic = rememberHaptics()
                Button(onClick = { haptic(Haptic.TICK); onPair(info) }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.action_pair)) }
            }
        }
    }
}
