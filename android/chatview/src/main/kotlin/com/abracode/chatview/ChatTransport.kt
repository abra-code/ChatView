package com.abracode.chatview

// Port of Sources/ChatView/ChatTransport.swift (the abstraction: capabilities + protocol + config slice + factory
// type). The built-in transports live in LocalChatTransport.kt / LocalP2PTransport.kt; the registry in
// ChatTransportRegistry.kt.
//
// A transport is the ONLY layer that knows a wire protocol. It emits a normalized ChatEvent stream and accepts
// normalized ChatCommands, so the store / view above it are identical no matter which protocol is active. Swift's
// AsyncStream<ChatEvent> maps to a kotlinx Channel drained by the store (a mechanical port of the single-consumer
// stream, NOT a redesign around Flow).

import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Which P2P (v2) conversation affordances a transport backs. The store consults this before emitting the
 * corresponding command (typing signals, read marks, paging, ...), and the view combines it with the document's
 * `features` config: an affordance appears only when BOTH the document enables it AND the transport supports it.
 * Every flag defaults to false, so a v1 transport (which does not set `capabilities`) advertises no v2 capability
 * and behaves exactly as before.
 */
data class ChatTransportCapabilities(
    val paging: Boolean = false,               // answers `.loadEarlier` with `.historyPage`
    val typing: Boolean = false,               // relays `.setTyping` / emits `.typingChanged`
    val reactions: Boolean = false,            // relays `.toggleReaction` / emits `.reactionsChanged`
    val editing: Boolean = false,              // relays `.editMessage` / emits `.messageEdited`
    val deletion: Boolean = false,             // relays `.deleteMessage` / emits `.messageDeleted`
    val replies: Boolean = false,              // relays `.sendMessage(replyTo:)`
    val readReceipts: Boolean = false,         // relays `.markRead` / emits status watermarks
    val fileTransfer: Boolean = false,         // emits `.fileAdded` / `.fileProgress`, relays `.cancelFileTransfer`
    val messageIdentity: Boolean = false,      // assigns server-side ids and confirms via `.messageIDConfirmed`
    val reportsConnectionState: Boolean = false, // emits `.connectionStateChanged`; the composer gates on `connected`
)

/**
 * One wire protocol's adapter. `events` is a single-consumer channel the store drains for the element's lifetime.
 * Construction is NOT part of the interface - a transport is built by the factory registered for its protocol name,
 * so each transport is free to have whatever constructor it needs.
 */
interface ChatTransport {
    /** Begins the session (launch / connect / advertise options) and starts emitting events. */
    suspend fun start()

    /** Handles one normalized outbound command (a user turn, cancel, permission answer, option change). */
    suspend fun send(command: ChatCommand)

    /** The single-consumer event channel the store drains. Closed by [stop] so the drain completes. */
    val events: ReceiveChannel<ChatEvent>

    /** Ends the session and closes [events] so the store's drain completes. */
    suspend fun stop()

    /** The P2P affordances this transport backs. Defaults to none (a v1 transport is unaffected). */
    val capabilities: ChatTransportCapabilities
        get() = ChatTransportCapabilities()

    /**
     * Replaces the transport's wire history with a restored transcript's messages, so a continued conversation is
     * sent with its prior turns as context. `messages` are the transcript's message items in order (role + text);
     * non-message items are omitted. A transport whose history lives server-side may ignore it. Default: no-op.
     */
    fun primeHistory(messages: List<ChatMessage>) {}

    /**
     * Reserves any id namespaces this transport MINTS, so a turn continued after a transcript restore never reuses
     * an id already present in the loaded items. `ids` is EVERY item id in the restored transcript. Default: no-op
     * (only a transport that mints launch-reset per-turn ids a restore could re-alias needs this).
     */
    fun reserveIDs(seen: List<String>) {}
}

/**
 * The transport-relevant slice of a Chat element's configuration, handed to a transport factory. This is the ONLY
 * configuration a transport sees. `settings` is the host-injected `states["config"].transport` object verbatim; the
 * typed accessors are conveniences over it. Modeled as a kotlinx JsonObject (the parsed-JSON analog of Swift's
 * `[String: Any]`).
 */
class ChatTransportConfig(
    val protocolName: String = "",
    val settings: JsonObject = JsonObject(emptyMap()),
) {
    private fun primitive(key: String): JsonPrimitive? = settings[key] as? JsonPrimitive

    fun string(key: String): String? = primitive(key)?.takeIf { it.isString }?.content

    // A JSON string "true" is not a bool; a JSON number 0 / 1 is (Foundation `NSNumber as? Bool` bridging quirk).
    fun bool(key: String): Boolean? {
        val p = primitive(key) ?: return null
        if (p.isString) return null
        p.booleanOrNull?.let { return it }
        return when (p.intOrNull) {
            0 -> false
            1 -> true
            else -> null
        }
    }

    // Swift's `(NSNumber).intValue` truncates a float-encoded number (45.0 -> 45); match that (intOrNull is null for
    // a `45.0` primitive), while a string stays non-numeric.
    fun int(key: String): Int? = primitive(key)?.takeUnless { it.isString }?.let { it.intOrNull ?: it.doubleOrNull?.toInt() }

    fun double(key: String): Double? = primitive(key)?.takeUnless { it.isString }?.doubleOrNull

    // `as? [String]` is all-or-nothing: any non-string element fails the whole cast (yields null).
    fun stringArray(key: String): List<String>? {
        val array = settings[key] as? JsonArray ?: return null
        val strings = array.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: return null }
        return strings
    }

    fun dictionary(key: String): JsonObject? = settings[key] as? JsonObject

    fun dictionaryArray(key: String): List<JsonObject>? {
        val array = settings[key] as? JsonArray ?: return null
        val objects = array.map { it as? JsonObject ?: return null }
        return objects
    }
}

/**
 * Builds a transport from its configuration and logger. A protocol's module registers one of these under its name;
 * the registry invokes it when a document selects that protocol. Throwing degrades the element to the built-in
 * `local` transport (unregistered name) or leaves it deferred (registered-but-throwing) with a logged reason.
 */
fun interface ChatTransportFactory {
    fun create(config: ChatTransportConfig, logger: ChatLogger): ChatTransport
}
