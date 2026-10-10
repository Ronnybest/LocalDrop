package dev.localdrop.app

import android.app.Application
import dev.localdrop.feature.settings.CrashReports

class LocalDropApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        CrashReports.apply(this)
        container = AppContainer(this)
    }
}
