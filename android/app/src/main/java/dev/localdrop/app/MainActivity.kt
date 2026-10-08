package dev.localdrop.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import dev.localdrop.app.ui.LocalDropTheme
import dev.localdrop.feature.transfer.TransferService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            LocalDropTheme {
                LocalDropAppUi()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Opening LocalDrop is a moment the Mac may be around: kept sends get another try. Only
        // the foreground may start the service, which is why a parked send waits for this.
        val store = (application as LocalDropApplication).container.outgoingStore
        lifecycleScope.launch {
            val waiting = withContext(Dispatchers.IO) {
                store.load()
                store.items.value.isNotEmpty()
            }
            if (waiting) TransferService.resume(this@MainActivity)
        }
    }
}
