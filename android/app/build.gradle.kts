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
        applicationId = "dev.localdrop"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            optimization {
                enable = true
            }
        }
        create("profile") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
    }
    testOptions {
        // core/* logs through android.util.Log; JVM tests run that code without a device.
        unitTests.isReturnDefaultValues = true
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
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.kotlinx.coroutines.android)
    debugImplementation(libs.androidx.compose.ui.tooling)
    testImplementation(libs.junit)
}
