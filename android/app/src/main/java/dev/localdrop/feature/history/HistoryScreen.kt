package dev.localdrop.feature.history

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.FilterChip
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.remember
import androidx.compose.ui.input.nestedscroll.nestedScroll
import dev.localdrop.app.ui.Segments
import java.util.Calendar
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.localdrop.R
import dev.localdrop.app.LocalDropApplication
import dev.localdrop.core.history.HistoryEntry
import dev.localdrop.core.history.HistoryStore
import dev.localdrop.feature.devices.HistoryActions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class HistoryViewModel(private val store: HistoryStore) : ViewModel() {
    val entries: StateFlow<List<HistoryEntry>> = store.entries

    init {
        viewModelScope.launch(Dispatchers.IO) { store.load() }
    }

    fun remove(entry: HistoryEntry) {
        viewModelScope.launch(Dispatchers.IO) { store.remove(entry.id) }
    }

    companion object {
        val Factory = viewModelFactory {
            initializer { HistoryViewModel((this[APPLICATION_KEY] as LocalDropApplication).container.historyStore) }
        }
    }
}

/** Everything of the last 30 days, newest first, one segmented group per day. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(onBack: () -> Unit, viewModel: HistoryViewModel = viewModel(factory = HistoryViewModel.Factory)) {
    val entries by viewModel.entries.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var filter by rememberSaveable { mutableStateOf(HistoryFilter.ALL) }
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text(stringResource(R.string.home_recent)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
                scrollBehavior = scroll,
            )
        },
    ) { padding ->
        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text(
                    stringResource(R.string.history_empty),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            return@Scaffold
        }
        val shown = when (filter) {
            HistoryFilter.ALL -> entries
            HistoryFilter.RECEIVED -> entries.filter { it.incoming }
            HistoryFilter.SENT -> entries.filterNot { it.incoming }
        }
        val days = shown.groupBy { dayOf(it.timeMs) }
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(Segments.Gap),
        ) {
            item(key = "filter") {
                // All, received or sent: on a long list, one direction at a time.
                Row(Modifier.animateItem().padding(bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    HistoryFilter.entries.forEach { option ->
                        FilterChip(
                            selected = filter == option,
                            onClick = { filter = option },
                            label = { Text(stringResource(option.label)) },
                        )
                    }
                }
            }
            if (shown.isEmpty()) {
                item(key = "none") {
                    Text(
                        stringResource(R.string.history_filter_empty),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.animateItem().padding(12.dp),
                    )
                }
            }
            days.forEach { (day, dayEntries) ->
                item(key = "day$day") {
                    Text(
                        dayTitle(dayEntries.first().timeMs),
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.animateItem().padding(start = 12.dp, top = 18.dp, bottom = 10.dp),
                    )
                }
                historyGroup(
                    entries = dayEntries,
                    style = DirectionStyle.TEXT,
                    onOpen = { HistoryActions.open(context, it) },
                    onDelete = { viewModel.remove(it) },
                )
            }
        }
    }
}

private enum class HistoryFilter(val label: Int) {
    ALL(R.string.history_filter_all),
    RECEIVED(R.string.history_received),
    SENT(R.string.history_sent),
}

private fun dayOf(timeMs: Long): Long {
    val calendar = Calendar.getInstance().apply { timeInMillis = timeMs }
    return calendar.get(Calendar.YEAR) * 1000L + calendar.get(Calendar.DAY_OF_YEAR)
}

/** "Today", "Yesterday", then "9 October". */
@Composable
private fun dayTitle(timeMs: Long): String {
    val context = LocalContext.current
    return when {
        DateUtils.isToday(timeMs) -> stringResource(R.string.history_today)
        DateUtils.isToday(timeMs + DateUtils.DAY_IN_MILLIS) -> stringResource(R.string.history_yesterday)
        else -> DateUtils.formatDateTime(context, timeMs, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_NO_YEAR)
    }
}
