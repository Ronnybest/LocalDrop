import com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension
import com.google.gms.googleservices.GoogleServicesPlugin

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "dev.localdrop"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        // The store's id, fixed with the first upload; the code keeps its own package.
        applicationId = "com.zepponapps.localdrop"
        minSdk = 29
        targetSdk = 36
        versionCode = 3
        versionName = "0.1.0"
        buildConfigField("boolean", "CRASH_REPORTS", "true")
    }

    // The upload key for Google Play lives with its owner, never in the repository: its path and
    // passwords come from ~/.gradle/gradle.properties (or -P / ORG_GRADLE_PROJECT_ variables).
    // Without them a release build is unsigned, as before; Play re-signs uploads with its own key.
    val upload = listOf("STORE_FILE", "STORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD")
        .associateWith { providers.gradleProperty("LOCALDROP_UPLOAD_$it").orNull }
    signingConfigs {
        if (upload.values.all { it != null }) {
            create("upload") {
                storeFile = file(upload.getValue("STORE_FILE")!!)
                storePassword = upload.getValue("STORE_PASSWORD")
                keyAlias = upload.getValue("KEY_ALIAS")
                keyPassword = upload.getValue("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            // A separate app, installed next to the one from Google Play (its signature differs).
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            // Crashes while developing are seen in logcat; they would only drown real ones.
            buildConfigField("boolean", "CRASH_REPORTS", "false")
        }
        release {
            optimization {
                enable = true
            }
            // The same switch the old way: the Crashlytics plugin reads only this one to inject
            // the mapping id and upload mapping.txt, without which crash reports stay obfuscated.
            isMinifyEnabled = true
            signingConfig = signingConfigs.findByName("upload")
        }
        create("profile") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
            // Installed over the debug app, with its data: same id, same signature.
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-profile"
            buildConfigField("boolean", "CRASH_REPORTS", "false")
        }
    }
    // Profile builds replace the debug app on the phone: the same name and DEBUG icon.
    sourceSets.getByName("profile").res.directories.add("src/debug/res")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions {
        // core/* logs through android.util.Log; JVM tests run that code without a device.
        unitTests.isReturnDefaultValues = true
    }
}

// Crash reports go to the owner's Firebase project. Its google-services.json isn't in the
// repository, so other builds have no Firebase configuration and send nothing. It sits in
// src/release: the file knows only the store's application id, so debug and profile builds
// (".debug") go without Firebase, as they send no crash reports anyway.
if (file("src/release/google-services.json").exists()) {
    apply(plugin = libs.plugins.google.services.get().pluginId)
    apply(plugin = libs.plugins.firebase.crashlytics.get().pluginId)
    configure<GoogleServicesPlugin.GoogleServicesPluginConfig> {
        missingGoogleServicesStrategy = GoogleServicesPlugin.MissingGoogleServicesStrategy.IGNORE
    }
    // Without a config file the task's cache key matches a run from when it had one: the build
    // cache would hand debug builds the store app's Firebase values. Those builds aren't cached.
    tasks.matching { it.name.endsWith("GoogleServices") && !it.name.contains("Release") }.configureEach {
        outputs.doNotCacheIf("no google-services.json for this build type") { true }
    }
    // Profile builds are minified like release but have no Firebase app to upload a mapping to.
    (android.buildTypes.getByName("profile") as ExtensionAware).extensions.configure<CrashlyticsExtension> {
        mappingFileUploadEnabled = false
    }
}

kotlin {
    compilerOptions {
        // Material 3 Expressive (shapes, loading indicator, button groups, motion) is marked
        // experimental in material3 1.5; the whole UI is built on it.
        optIn.add("androidx.compose.material3.ExperimentalMaterial3ExpressiveApi")
    }
}

tasks.withType<Test>().configureEach {
    // Shared with the Mac's tests (ProtocolVectorsTest): a change there reruns the tests.
    inputs.file(rootProject.file("../protocol/test-vectors.properties")).withPathSensitivity(PathSensitivity.NONE)
    // Opt-in interop test against a running macOS app (see MacHandshakeIntegrationTest).
    listOf("LOCALDROP_MAC_PORT", "LOCALDROP_MAC_ID", "LOCALDROP_MAC_PAIRING").forEach { name ->
        System.getenv(name)?.let { environment(name, it) }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.navigation3.runtime)
    implementation(libs.androidx.navigation3.ui)
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.kotlinx.coroutines.android)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.crashlytics)
    implementation(libs.androidx.fragment)
    debugImplementation(libs.androidx.compose.ui.tooling)
    testImplementation(libs.junit)
}
