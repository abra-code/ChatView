// The demo app module. Mirrors the Apple ChatViewDemo idea: standalone People / Group / ReadOnly chat screens
// wiring the ChatView composable directly (no ActionUI). Stage A2 ships a minimal shell that exercises the
// Compose toolchain end-to-end and depends on :chatview to prove the composite resolves; A8 fills in the screens.

plugins {
    // Built-in Kotlin (AGP 9.2) + the Compose compiler plugin; no standalone kotlin.android plugin.
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.abracode.chatview.demo"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.abracode.chatview.demo"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":chatview"))

    // The demo builds the operational config / restored transcript as kotlinx JSON (buildJsonObject, parseToJsonElement)
    // before handing them to ChatConfiguration / the content source. Runtime lib only - the demo declares no
    // @Serializable types, so it needs no serialization compiler plugin.
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)
}
