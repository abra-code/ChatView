package com.abracode.chatview

// Shared test helpers for the cross-platform JSON interop gate (plan section 8).
//
// - canonicalJson: a sorted-keys, whitespace-free rendering, so a Kotlin re-encode can be compared byte-for-byte
//   against a Swift `.sortedKeys` golden where no Double-typed model field is present.
// - assertJsonSemanticallyEqual: the PRIMARY gate - a numeric-normalizing tree walk. Raw JsonElement equality is
//   insufficient because a Swift-emitted whole Double (`800`) and the Kotlin re-encode (`800.0`) are unequal
//   primitives; this walk compares numeric primitives by their double value and everything else strictly.
// - fixturesDir: the repo-root Fixtures/ directory, located via the `chatview.fixtures.dir` system property the
//   Gradle test task sets (so a test never depends on the JVM working directory).

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import java.io.File

/** Sorted-keys, compact JSON rendering. ASCII keys sort identically to Swift's `.sortedKeys`. */
fun canonicalJson(element: JsonElement): String = when (element) {
    is JsonObject -> element.entries
        .sortedBy { it.key }
        .joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) ->
            "${JsonPrimitive(key)}:${canonicalJson(value)}"
        }
    is JsonArray -> element.joinToString(separator = ",", prefix = "[", postfix = "]") { canonicalJson(it) }
    is JsonPrimitive -> element.toString()
}

/**
 * The primary interop assertion: walks both trees and, when both sides are non-string numeric primitives, compares
 * their double values; everything else (keys, nesting, strings, booleans, nulls, array order) compares strictly.
 */
fun assertJsonSemanticallyEqual(expected: JsonElement, actual: JsonElement, path: String = "$") {
    when (expected) {
        is JsonObject -> {
            if (actual !is JsonObject) return fail("$path: expected object, got ${actual::class.simpleName}")
            assertEquals("$path: object keys differ", expected.keys.sorted(), actual.keys.sorted())
            for ((key, value) in expected) {
                assertJsonSemanticallyEqual(value, actual.getValue(key), "$path.$key")
            }
        }
        is JsonArray -> {
            if (actual !is JsonArray) return fail("$path: expected array, got ${actual::class.simpleName}")
            assertEquals("$path: array size differs", expected.size, actual.size)
            expected.forEachIndexed { index, value ->
                assertJsonSemanticallyEqual(value, actual[index], "$path[$index]")
            }
        }
        is JsonPrimitive -> {
            if (actual !is JsonPrimitive) return fail("$path: expected primitive, got ${actual::class.simpleName}")
            val expectedNumber = if (expected.isString || expected is JsonNull) null else expected.doubleOrNull
            val actualNumber = if (actual.isString || actual is JsonNull) null else actual.doubleOrNull
            if (expectedNumber != null && actualNumber != null) {
                assertEquals("$path: numeric value differs", expectedNumber, actualNumber, 0.0)
            } else {
                assertEquals("$path: primitive differs", expected, actual)
            }
        }
    }
}

/** The repo-root Fixtures/ directory, from the `chatview.fixtures.dir` system property. */
fun fixturesDir(): File {
    val path = System.getProperty("chatview.fixtures.dir")
        ?: error("chatview.fixtures.dir system property is not set (see chatview/build.gradle.kts)")
    val dir = File(path)
    check(dir.isDirectory) { "Fixtures directory does not exist: $path" }
    return dir
}

/** Reads a fixture file's text (UTF-8). */
fun readFixture(name: String): String = fixturesDir().resolve(name).readText(Charsets.UTF_8)
