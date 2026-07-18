package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatConfigV2Tests.swift.
//
// Tests for the person-to-person / group (v2) config layer: the new appearance flags (showTimestamps with its
// alignment-conditional default, showAvatars, showDeliveryStatus) and the `features` gate object. The guardrail: a
// v1 (single-alignment) configuration keeps its exact defaults, so these are inert unless a host opts in.

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatConfigV2Test {

    private val logger = object : ChatLogger {
        override fun log(message: String, level: ChatLogLevel) {}
    }

    private fun config(properties: JsonObject = JsonObject(emptyMap())): ChatConfiguration =
        ChatConfiguration.fromJson(properties, logger)

    // MARK: - Appearance

    @Test
    fun showTimestampsDefaultsToAlignment() {
        assertFalse("single (default) alignment -> timestamps off", config().showTimestamps)
        assertFalse(config(buildJsonObject { putJsonObject("appearance") { put("alignment", "single") } }).showTimestamps)
        assertTrue(
            "dual alignment -> timestamps on",
            config(buildJsonObject { putJsonObject("appearance") { put("alignment", "dual") } }).showTimestamps,
        )
    }

    @Test
    fun showTimestampsExplicitOverridesTheAlignmentDefault() {
        assertTrue(
            config(buildJsonObject { putJsonObject("appearance") { put("alignment", "single"); put("showTimestamps", true) } }).showTimestamps,
        )
        assertFalse(
            config(buildJsonObject { putJsonObject("appearance") { put("alignment", "dual"); put("showTimestamps", false) } }).showTimestamps,
        )
    }

    @Test
    fun showAvatarsDefaultsFalseAndParses() {
        assertFalse(config().showAvatars)
        assertTrue(config(buildJsonObject { putJsonObject("appearance") { put("showAvatars", true) } }).showAvatars)
    }

    @Test
    fun showDeliveryStatusDefaultsTrueAndParses() {
        assertTrue(config().showDeliveryStatus)
        assertFalse(config(buildJsonObject { putJsonObject("appearance") { put("showDeliveryStatus", false) } }).showDeliveryStatus)
    }

    @Test
    fun alignmentParsesDualWithoutAffectingV1Default() {
        assertEquals(ChatConfiguration.Alignment.SINGLE, config().alignment)
        assertEquals(
            ChatConfiguration.Alignment.DUAL,
            config(buildJsonObject { putJsonObject("appearance") { put("alignment", "dual") } }).alignment,
        )
    }

    // MARK: - Features

    @Test
    fun featuresDefaultAllFalse() {
        val f = config().features
        assertFalse(f.reactions)
        assertFalse(f.editing)
        assertFalse(f.deletion)
        assertFalse(f.replies)
    }

    // Not a Swift port: locks the Foundation `NSNumber as? Bool` bridging quirk that Swift inherits via
    // JSONSerialization - a JSON number 0 / 1 in a bool slot casts to false / true, while any other number or a
    // string does not.
    @Test
    fun numericZeroOrOneParsesAsBoolLikeSwiftBridging() {
        assertTrue(config(buildJsonObject { putJsonObject("appearance") { put("showAvatars", 1) } }).showAvatars)
        assertFalse(config(buildJsonObject { putJsonObject("appearance") { put("showDeliveryStatus", 0) } }).showDeliveryStatus)
        // A non-0/1 number is not a bool: falls back to the default (showDeliveryStatus default true).
        assertTrue(config(buildJsonObject { putJsonObject("appearance") { put("showDeliveryStatus", 2) } }).showDeliveryStatus)
        // A JSON string "true" is not a bool either.
        assertFalse(config(buildJsonObject { putJsonObject("appearance") { put("showAvatars", "true") } }).showAvatars)
    }

    @Test
    fun featuresParse() {
        val f = config(
            buildJsonObject {
                putJsonObject("features") {
                    put("reactions", true)
                    put("editing", true)
                    put("deletion", false)
                    put("replies", true)
                }
            },
        ).features
        assertTrue(f.reactions)
        assertTrue(f.editing)
        assertFalse(f.deletion)
        assertTrue(f.replies)
    }
}
