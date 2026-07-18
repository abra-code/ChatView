// The ChatView library module. A 1:1 semantic port of Sources/ChatView (Swift): the frozen data model and
// hand-written codecs, the config parse, the pure scroll-pin / transcript-layout logic, the scheduler, the
// transport seam + local / local-p2p transports, the store state machine, and the Compose transcript + composer.
// The pure-logic layer is JVM-testable; the UI layer reproduces the SwiftUI behavior. Runtime dependencies are
// limited to the AndroidX/Compose baseline + kotlinx-coroutines + kotlinx-serialization + RichText (message
// Markdown) + AsyncImageCache (image items). No OkHttp / Ktor / markdown / Coil-Glide.
//
// Stage A2 scaffolds the module (coordinate, namespace, dependency surface, source sets); the ported sources
// arrive in A3-A7.

plugins {
    // AGP 9.2 ships built-in Kotlin support (it registers the `kotlin` extension), so the standalone
    // org.jetbrains.kotlin.android plugin is neither applied nor needed - only the Compose compiler plugin and
    // the kotlinx-serialization compiler plugin.
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Coordinate for consumption as a Gradle composite build: ActionUIAndroid declares a dependency on
// `com.abracode:chatview` and includeBuild substitutes this project for it (see settings.gradle.kts). The group
// must be set for that automatic substitution to match.
group = "com.abracode"
version = "0.1.0"

android {
    namespace = "com.abracode.chatview"
    compileSdk = 36

    defaultConfig {
        minSdk = 31
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        // Java 17 to match the RichText / AsyncImageCache libraries this module links.
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    // The cross-platform fixtures (A1) live at the repo root Fixtures/, shared byte-for-byte with the Swift
    // emitter. Mount them as unit-test resources so the JVM interop / replay suites (A3, A5) read THE SAME files
    // the Swift side emitted. This module is at android/chatview, so ../../Fixtures is the repo root Fixtures/.
    sourceSets {
        getByName("test") {
            resources.srcDir("../../Fixtures")
        }
    }

    // The pure-logic port (model / codecs / config / layout / pin / scheduler / store) is platform-free and runs
    // as fast JVM unit tests; it never touches android.* APIs, so default-value stubbing stays off.
    testOptions {
        unitTests.isReturnDefaultValues = false
    }
}

// The JVM unit suite also reads the SAME Fixtures/ via an absolute path, so a test never depends on the JVM
// working directory. rootDir is android/ (where settings.gradle.kts lives); its parent is the repo root.
tasks.withType(org.gradle.api.tasks.testing.Test::class.java).configureEach {
    systemProperty("chatview.fixtures.dir", rootDir.parentFile.resolve("Fixtures").absolutePath)
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.androidx.core.ktx)

    // Sibling standalone libraries, substituted for their local Gradle builds by includeBuild (settings.gradle.kts).
    // Same coordinates the Swift package depends on: RichText renders message Markdown, AsyncImageCache provides
    // CachedImage for image items.
    implementation("com.abracode:richtext")
    implementation("com.abracode:asyncimagecache")

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)

    // JVM unit tests (pure logic: model / codecs / config / layout / pin / scheduler / store; fixture replays).
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)

    // Instrumented tests (Compose transcript / composer: pin matrix, affordances, composer policies).
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
