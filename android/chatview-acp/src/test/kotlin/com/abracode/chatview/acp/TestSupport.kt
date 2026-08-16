package com.abracode.chatview.acp

// Shared fakes for the :chatview-acp suites. The Kotlin twin of the ScriptedSocket / RemoteTestLogger helpers in
// Tests/ACPTests/ChatACPRemoteTests.swift: a WebSocket that records what the client sent and lets a test inject
// frames and closures, plus a recording logger.

import com.abracode.chatview.ChatEvent
import com.abracode.chatview.ChatLogLevel
import com.abracode.chatview.ChatLogger
import com.abracode.chatview.ChatTransport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okio.ByteString
import java.io.IOException

/** A logger that keeps every line so a test can assert on what was reported. */
class RecordingLogger : ChatLogger {
    private val lines = mutableListOf<String>()

    override fun log(message: String, level: ChatLogLevel) {
        synchronized(lines) { lines.add("[$level] $message") }
    }

    fun all(): List<String> = synchronized(lines) { lines.toList() }

    fun contains(fragment: String): Boolean = all().any { it.contains(fragment) }
}

/**
 * A WebSocket the test drives by hand. `sent` records every frame the client wrote; `onSend` lets a test answer a
 * request the moment it is written, which is how the scripted bridge in these suites replies.
 */
class ScriptedSocket : WebSocket {

    private val sentFrames = mutableListOf<String>()
    private val lock = Any()
    private var canceled = false
    private var closedWith: Int? = null

    /** Invoked with (this socket, the parsed frame) for every frame the client sends. */
    var onSend: ((ScriptedSocket, JsonObject) -> Unit)? = null

    /** Set by the test to the connection's listener so `deliver` can push frames inward. */
    var listener: okhttp3.WebSocketListener? = null

    /** The upgrade request the factory was handed, so a test can assert on the Authorization header. */
    var upgradeRequest: Request? = null

    fun sent(): List<String> = synchronized(lock) { sentFrames.toList() }

    fun sentObjects(): List<JsonObject> = sent().mapNotNull { runCatching { Json.parseToJsonElement(it).jsonObject }.getOrNull() }

    /** Every frame the client sent for one method. */
    fun frames(method: String): List<JsonObject> = sentObjects().filter { it.str("method") == method }

    /** Every response the client sent (its answers to the bridge's own requests). */
    fun results(): List<JsonObject> = sentObjects().filter { it["result"] is JsonObject }

    fun isCanceled(): Boolean = synchronized(lock) { canceled }

    fun closeCode(): Int? = synchronized(lock) { closedWith }

    /** Pushes one JSON frame into the client, as the bridge would. */
    fun deliver(message: JsonObject) {
        deliverRaw(Json.encodeToString(JsonObject.serializer(), message))
    }

    fun deliverRaw(text: String) {
        listener?.onMessage(this, text)
    }

    fun open() {
        listener?.onOpen(this, fakeResponse())
    }

    fun fail(error: Throwable) {
        listener?.onFailure(this, error, null)
    }

    /** The network going away under a live session: what a phone does every time it loses signal. */
    fun dropConnection() {
        fail(IOException("the connection dropped"))
    }

    /** Closed by either half of the handshake, which is what the watchdog and teardown assertions look for. */
    fun isClosed(): Boolean = synchronized(lock) { canceled || closedWith != null }

    // MARK: - WebSocket

    override fun cancel() {
        synchronized(lock) { canceled = true }
    }

    override fun close(code: Int, reason: String?): Boolean {
        val first = synchronized(lock) {
            if (closedWith != null) {
                false
            } else {
                closedWith = code
                true
            }
        }
        return first
    }

    override fun queueSize(): Long = 0

    override fun request(): Request = upgradeRequest ?: Request.Builder().url("http://localhost/acp").build()

    override fun send(text: String): Boolean {
        synchronized(lock) { sentFrames.add(text) }
        val parsed = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return true
        onSend?.invoke(this, parsed)
        return true
    }

    override fun send(bytes: ByteString): Boolean = send(bytes.utf8())

    private fun fakeResponse(): Response = Response.Builder()
        .request(request())
        .protocol(okhttp3.Protocol.HTTP_1_1)
        .code(101)
        .message("Switching Protocols")
        .build()
}

/**
 * Hands out [ScriptedSocket]s in place of real ones. `configure` is invoked with the attempt number, so a test can
 * make attempt 0 behave differently from the reconnect that follows it.
 */
class ScriptedSocketFactory(private val configure: (Int, ScriptedSocket) -> Unit) : WebSocket.Factory {

    private val lock = Any()
    private val produced = mutableListOf<ScriptedSocket>()

    override fun newWebSocket(request: Request, listener: okhttp3.WebSocketListener): WebSocket {
        val socket = ScriptedSocket()
        socket.listener = listener
        socket.upgradeRequest = request
        val index = synchronized(lock) {
            produced.add(socket)
            produced.size - 1
        }
        configure(index, socket)
        socket.open()
        return socket
    }

    fun sockets(): List<ScriptedSocket> = synchronized(lock) { produced.toList() }

    fun socket(index: Int): ScriptedSocket? = sockets().getOrNull(index)
}

/**
 * A bridge written FROM the wire spec (plan section 7), deliberately: this double is the appendix's Kotlin-side
 * conformance check, the twin of Swift's ScriptedBridge. It answers the client's requests and lets a test push
 * seq-stamped notifications.
 */
class ScriptedBridge(val sessionID: String = "sess-1") {

    private val lock = Any()
    private var seq = 0
    private var lastAttachAfterSeq: Int? = null

    var latestSeqAtAttach = 0
    var stateAtAttach = "live"
    var activeTurnAtAttach: Int? = null

    /** Notifications the bridge streams after answering an attach, as (method, params-without-seq-or-session). */
    var replayOnAttach: List<Pair<String, JsonObject>> = emptyList()

    /** Makes attach answer with a DIFFERENT session id than the one requested (the 4.2a mismatch case). */
    var attachSessionIDOverride: String? = null

    /** The turn number `session/prompt` reports back. */
    var promptTurn = 1

    /** Wires this bridge to a socket: it answers requests as they arrive. */
    fun attachTo(socket: ScriptedSocket) {
        socket.onSend = { sending, message -> handle(message, sending) }
    }

    private fun handle(message: JsonObject, socket: ScriptedSocket) {
        val method = message.str("method") ?: return
        val id = message.element("id") ?: return
        when (method) {
            "initialize" -> socket.deliver(
                response(id) {
                    put("protocolVersion", 1)
                    putJsonObject("agentCapabilities") { put("loadSession", false) }
                    putJsonObject("agentInfo") {
                        put("name", "scripted-agent")
                        put("version", "9.9")
                    }
                    putJsonArray("authMethods") {}
                    putJsonObject("bridge") {
                        put("name", "chatview-acp-bridge")
                        put("version", "0.1.0")
                        put("protocol", 1)
                        putJsonObject("capabilities") {
                            put("attachReplay", true)
                            put("sessions", true)
                        }
                    }
                },
            )

            "session/new" -> socket.deliver(response(id) { put("sessionId", sessionID) })

            "bridge/sessions" -> socket.deliver(
                response(id) {
                    putJsonArray("sessions") {
                        add(
                            buildJsonObject {
                                put("sessionId", sessionID)
                                put("state", "live")
                                put("createdAt", "2026-08-11T00:00:00Z")
                                put("lastActivityAt", "2026-08-11T00:00:00Z")
                                put("latestSeq", latestSeqAtAttach)
                                put("title", "t")
                            },
                        )
                    }
                },
            )

            "bridge/attach" -> {
                val after = (message["params"] as? JsonObject)?.num("afterSeq") ?: 0
                synchronized(lock) { lastAttachAfterSeq = after }
                socket.deliver(
                    response(id) {
                        put("sessionId", attachSessionIDOverride ?: sessionID)
                        put("state", stateAtAttach)
                        put("latestSeq", latestSeqAtAttach)
                        activeTurnAtAttach?.let { put("activeTurn", it) }
                        putJsonArray("configOptions") {}
                        if (stateAtAttach == "ended") {
                            put("endedReason", "agent_exit")
                        }
                    },
                )
                // On its own thread, because the real bridge cannot possibly deliver replayed notifications before
                // the response that announces them. Delivering them inline would let this double pass an ordering
                // the real server never produces.
                val entries = replayOnAttach
                if (entries.isNotEmpty()) {
                    Thread {
                        for ((replayMethod, params) in entries) {
                            socket.deliver(
                                buildJsonObject {
                                    put("jsonrpc", "2.0")
                                    put("method", replayMethod)
                                    put("params", params)
                                },
                            )
                        }
                    }.start()
                }
            }

            "session/prompt" -> socket.deliver(response(id) { put("turn", promptTurn) })

            "session/set_config_option" -> socket.deliver(response(id) {})

            else -> socket.deliver(
                buildJsonObject {
                    put("jsonrpc", "2.0")
                    put("id", id)
                    putJsonObject("error") {
                        put("code", -32601)
                        put("message", "unknown method")
                    }
                },
            )
        }
    }

    /** Pushes a seq-stamped notification, exactly as the real bridge does. Returns the seq it used. */
    fun push(socket: ScriptedSocket, method: String, params: JsonObject): Int {
        val next = synchronized(lock) { ++seq }
        pushAt(socket, next, method, params)
        return next
    }

    /** Pushes at an explicit seq, for the duplicate-delivery case. */
    fun pushAt(socket: ScriptedSocket, value: Int, method: String, params: JsonObject) {
        synchronized(lock) { seq = maxOf(seq, value) }
        socket.deliver(
            buildJsonObject {
                put("jsonrpc", "2.0")
                put("method", method)
                put("params", stamped(params, value))
            },
        )
    }

    /** The `afterSeq` of the most recent attach, which is what the resume contract is all about. */
    fun attachCursor(): Int? = synchronized(lock) { lastAttachAfterSeq }

    /** A notification payload as it appears in an attach replay: session id and seq already stamped in. */
    fun replayEntry(seq: Int, params: JsonObject): JsonObject = stamped(params, seq)

    private fun stamped(params: JsonObject, seq: Int): JsonObject = buildJsonObject {
        for ((key, value) in params) {
            put(key, value)
        }
        put("sessionId", sessionID)
        put("seq", seq)
    }

    private fun response(id: JsonElement, result: JsonObjectBuilder.() -> Unit): JsonObject = buildJsonObject {
        put("jsonrpc", "2.0")
        put("id", id)
        put("result", buildJsonObject(result))
    }
}

/**
 * Drains a transport's event channel into a list, and renders it as the compact log the assertions read against -
 * the same rendering the Swift suite uses, so a failure is comparable across platforms.
 */
class EventCollector {

    private val lock = Any()
    private val stored = mutableListOf<ChatEvent>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null

    fun start(transport: ChatTransport) {
        job = scope.launch {
            for (event in transport.events) {
                synchronized(lock) { stored.add(event) }
            }
        }
    }

    fun stop() {
        job?.cancel()
        scope.cancel()
    }

    fun events(): List<ChatEvent> = synchronized(lock) { stored.toList() }

    fun log(): List<String> = events().map { event ->
        when (event) {
            is ChatEvent.ConnectionStateChanged -> "state:${event.state.name.lowercase()}"
            is ChatEvent.SessionReady -> "ready:${event.sessionID}"
            is ChatEvent.SessionInfo -> "info:${event.info.sessionId}:resumed=${event.info.resumed}"
            is ChatEvent.MessageStart -> "start:${event.itemID}:${event.role.name.lowercase()}"
            is ChatEvent.MessageDelta -> "delta:${event.itemID}:${event.text}"
            is ChatEvent.MessageEnd -> "end:${event.itemID}:${event.stopReason ?: "-"}"
            is ChatEvent.ThoughtDelta -> "thought:${event.itemID}:${event.text}"
            is ChatEvent.ToolCall -> "tool:${event.call.id}"
            is ChatEvent.ToolCallUpdateEvent -> "toolupdate:${event.update.id}"
            is ChatEvent.PermissionRequestEvent -> "perm:${event.request.id}"
            is ChatEvent.PermissionResolved -> "permresolved:${event.requestID}"
            is ChatEvent.ResumeCheckpoint -> "checkpoint:${event.sessionID}:${event.afterSeq}"
            is ChatEvent.Error -> "error:${event.recoverable}:${event.message}"
            is ChatEvent.System -> "system:${event.text}"
            is ChatEvent.Usage -> "usage"
            is ChatEvent.Plan -> "plan"
            else -> "other"
        }
    }

    /** Polls until the predicate holds, then returns; fails the test with the log so far if it never does. */
    fun waitFor(description: String, timeoutMs: Long = 3_000, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (System.nanoTime() < deadline) {
            if (predicate()) {
                return
            }
            Thread.sleep(2)
        }
        org.junit.Assert.fail("timed out waiting for $description; saw ${log()}")
    }
}

/** `element["key"]` as a plain string, for terse assertions on captured frames. */
fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

/** `element["key"]` as a plain int, for terse assertions on captured frames. */
fun JsonObject.num(key: String): Int? = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.content?.toIntOrNull()

/** The raw element under a key, for echoing an id back verbatim. */
fun JsonObject.element(key: String): JsonElement? = this[key]
