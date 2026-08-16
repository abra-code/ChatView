// Gradle settings for the self-contained Android build of ChatView.
//
// This build is consumed by ActionUIAndroid as a composite build:
//   includeBuild("../../ChatView/android") { name = "chatview" }
// which substitutes the `com.abracode:chatview` module in place of any binary dependency. Keeping the build
// self-contained (its own settings + wrapper) means it also builds and tests standalone.
//
// ChatView pulls in RichText (message Markdown) and AsyncImageCache (image items) the same way the Swift
// package does - via sibling composite builds, so the `com.abracode:richtext` / `com.abracode:asyncimagecache`
// dependencies in :chatview resolve to the local source projects instead of published artifacts. RichText in
// turn includeBuilds the SAME AsyncImageCache/android directory; Gradle coalesces the two includes into one
// build (this is the identical diamond ActionUIAndroid already tolerates for :addon-richtext).

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    // Auto-provisions the JDK toolchain the Gradle daemon requests (gradle/gradle-daemon-jvm.properties),
    // mirroring ActionUIAndroid so a fresh checkout configures without a hand-installed JDK.
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

// Both sibling Android builds live two directories up (this settings file is at ChatView/android). AsyncImageCache
// is included first under its default, directory-derived name ("android"); RichText is named explicitly because
// its directory is ALSO "android" and would collide on the default build path. The name is just a build
// identifier - dependency substitution is by the com.abracode:* coordinate, so naming does not affect it.
includeBuild("../../AsyncImageCache/android")
includeBuild("../../RichText/android") { name = "richtext" }

rootProject.name = "ChatView"
include(":chatview")
// The remote-agent transport ("acp-remote"). Its own module so the OkHttp dependency stays opt-in: a host that
// links only :chatview never pulls it (remote-agent plan 3.4).
include(":chatview-acp")
include(":demo")
