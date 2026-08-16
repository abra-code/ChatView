// The remote ACP transport module: the Kotlin twin of the Swift ChatViewACP product's `acp-remote` transport.
// It speaks the bridge wire protocol (Private/ChatView_Remote_Agent_Plan.md section 7) to a chatview-acp-bridge
// over one WebSocket, and registers itself with ChatTransportRegistry under the protocol name "acp-remote".
//
// Separate module on purpose, mirroring how Swift keeps transports in their own products: the OkHttp dependency
// is the sanctioned exception to the :chatview no-OkHttp rule (plan 3.4) and must not leak into the component.
// Hand-rolling RFC 6455 - framing, masking, fragmentation, ping/pong, close handshake, TLS - is several hundred
// lines of security-sensitive code with none of OkHttp's hardening, and java.net.http.HttpClient does not exist
// on Android. OkHttp is `implementation`-scoped here, so a host that never links this module never pulls it.
//
// There is no `acp` (stdio subprocess) twin and never will be: Android cannot spawn an agent process.

plugins {
    // AGP 9.x ships built-in Kotlin support; only the serialization compiler plugin is applied on top. No Compose
    // plugin - this module has no UI.
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
}

// Coordinate for consumption as a Gradle composite build, matching :chatview's.
group = "com.abracode"
version = "0.1.0"

android {
    namespace = "com.abracode.chatview.acp"
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
        // Java 17, matching :chatview and the sibling libraries.
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Everything here is platform-free JSON / coroutines / socket plumbing, so the whole module is JVM-testable:
    // the wire parsers and the JSON-RPC connection run as plain unit tests, and the transport drives a scripted
    // bridge over a mockwebserver3 WebSocket.
    testOptions {
        unitTests.isReturnDefaultValues = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":chatview"))
    implementation(libs.okhttp)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.mockwebserver3)
}
