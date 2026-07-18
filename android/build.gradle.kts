// Root build script. Plugins are declared here with `apply false` so the version catalog pins one version per
// plugin across every module; each module applies the ones it needs.

plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}
