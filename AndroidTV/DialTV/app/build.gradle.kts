import java.util.Properties

import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    // The shared code (data, playback) lives in package app.dial, so the namespace stays the same;
    // the app's own id is different, so it installs next to the phone app.
    namespace = "app.dial"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.nodescraper.dial.tv"
        minSdk = 29
        targetSdk = 36
        versionCode = 34
        versionName = "0.34"
    }

    // Release signing: put your upload key's details in keystore.properties next to the settings file (see docs/STORE.md).
    // Without that file the release build is signed with the debug key, which is fine for installing on your own devices
    // but not for the store.
    val keystoreFile = rootProject.file("keystore.properties")
    val keystore = Properties().apply { if (keystoreFile.exists()) keystoreFile.inputStream().use { load(it) } }
    signingConfigs {
        if (keystoreFile.exists()) create("release") {
            storeFile = rootProject.file(keystore.getProperty("storeFile"))
            storePassword = keystore.getProperty("storePassword")
            keyAlias = keystore.getProperty("keyAlias")
            keyPassword = keystore.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            // R8 shrinks and optimises the code (the phone app does the same): about a tenth of the size, and a faster start on TV hardware.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }

    sourceSets {
        getByName("main") {
            // Dial's data layer and player are shared with the phone app; the screens are not.
            java.srcDir("../../DialAndroid/app/src/main/java")
            res.srcDir("../../DialAndroid/app/src/main/res")
        }
    }
}

// The phone app's screens (and its activity) stay out of the TV app.
tasks.withType<KotlinCompile>().configureEach {
    exclude("app/dial/ui/**", "app/dial/MainActivity.kt")
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(libs.androidx.lifecycle.viewmodel)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    implementation(libs.tv.material)
    implementation(libs.tv.foundation)

    implementation(libs.media3.exoplayer)
    implementation(libs.media3.session)
    implementation(libs.coroutines.guava)

    implementation(libs.coil.compose)
    implementation(libs.coil.okhttp)
    implementation(libs.okhttp)
    implementation(libs.serialization.json)
    implementation(libs.palette)
}
