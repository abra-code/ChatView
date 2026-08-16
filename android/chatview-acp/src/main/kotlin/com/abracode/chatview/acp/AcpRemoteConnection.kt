package com.abracode.chatview.acp

// Port of Sources/ACP/ACPRemoteConnection.swift.
//
// The client half of the bridge protocol: JSON-RPC 2.0 over one WebSocket, one message per TEXT frame. The dispatch
// shape is deliberately identical to the Swift file and to ACPConnection before it - method+id is a request, method
// alone is a notification, id alone is a response - minus any line buffering, since a frame is already a message.
//
// Two invariants carried over from the stdio transport, both learned the hard way there:
//
// I1 - a handshake watchdog must close the SOCKET, never race the request. The transport arms its watchdog around
//      the connect sequence and closes this connection on expiry; the parked request then fails through the normal
//      error path instead of being abandoned by a timeout wrapper.
// I2 - close-fails-everything, exactly once. A connection object is single-use: one per attempt. Reconnect logic
//      lives OUTSIDE it, in the transport.
//
// Keepalive is OkHttp's job here rather than a task of our own: the client the transport builds sets pingInterval,
// and OkHttp fails the connection when a pong does not come back in time. That covers what the Swift file's ping
// task exists for - a silently reaped flow (NAT timeout, a phone changing networks) never delivers a receive error,
// so without it a client can sit "connected" on a dead socket, which on a phone is the common case.

import com.abracode.chatview.ChatLogLevel
import com.abracode.chatview.ChatLogger
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** A JSON-RPC error returned by the bridge, or a connection failure. */
class AcpRemoteError(val code: Int?, override val message: String) : Exception(message) {
    override fun toString(): String = if (code != null) "$message (code $code)" else message
}

class AcpRemoteConnection(
    private val logger: ChatLogger,
    private val scope: CoroutineScope,
    private val onOpen: () -> Unit,
    private val onNotification: (String, JsonObject) -> Unit,
    /** A request FROM the bridge (only `session/request_permission` today). Null answers "method not found". */
    private val onRequest: suspend (String, JsonObject) -> JsonObject?,
    private val onClose: (Throwable?) -> Unit,
) {

    private val lock = Any()
    private var socket: WebSocket? = null
    private var nextRequestID = 1
    private val pending = mutableMapOf<Int, CancellableContinuation<JsonObject>>()
    private var closed = false

    /**
     * The OkHttp listener that feeds this connection. Every callback carries the WebSocket it belongs to, so the
     * connection adopts the socket from the callback itself: there is no window in which a frame arrives before the
     * transport has handed the socket over.
     */
    fun listener(): WebSocketListener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            adopt(webSocket)
            this@AcpRemoteConnection.onOpen.invoke()
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            adopt(webSocket)
            handleFrame(text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            // The wire spec is text-only; a binary frame that happens to be UTF-8 JSON is still honored, mirroring
            // the Swift socket's handling of a .data message.
            adopt(webSocket)
            handleFrame(bytes.utf8())
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            close(t)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            // The peer is going away. Treat it as closed now rather than waiting for onClosed: a pending request
            // must fail as soon as the answer can no longer arrive.
            close(AcpRemoteError(null, "the connection to the agent bridge closed (code $code)"))
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            close(AcpRemoteError(null, "the connection to the agent bridge closed (code $code)"))
        }
    }

    /**
     * Hands the connection its socket. Safe to call more than once (the listener does it on every callback); a
     * connection closed before the socket arrived closes it rather than leaving a live socket behind.
     */
    fun adopt(webSocket: WebSocket) {
        val refused = synchronized(lock) {
            if (closed) {
                true
            } else {
                socket = webSocket
                false
            }
        }
        if (refused) {
            webSocket.cancel()
        }
    }

    // MARK: - Inbound

    /** Internal for tests: the frame dispatcher, drivable without a server. */
    fun handleFrame(text: String) {
        if (synchronized(lock) { closed }) {
            // A closed connection is done, permanently (I2). OkHttp can deliver a frame that was already in the
            // reader's hands when close() ran, and routing it would push events into a transport that has torn
            // down - or, after a reconnect, into a session state that a newer connection now owns.
            return
        }
        val message = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
        if (message == null) {
            // A frame we cannot parse is dropped, not fatal: forward compatibility beats tearing down a working
            // session over one bad message.
            logger.log("acp-remote: dropping an unparseable frame", ChatLogLevel.WARNING)
            return
        }

        val method = (message["method"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (method != null) {
            val params = message["params"] as? JsonObject ?: JsonObject(emptyMap())
            // An `id` of ANY shape (including null) makes this a request, matching the Swift dispatch.
            val id = if (message.containsKey("id")) message["id"] else null
            if (id != null) {
                handleInboundRequest(method, id, params)
            } else {
                onNotification(method, params)
            }
            return
        }

        val responseID = (message["id"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull ?: return
        val continuation = synchronized(lock) { pending.remove(responseID) }
        if (continuation == null) {
            logger.log("acp-remote: response for an unknown request id $responseID", ChatLogLevel.WARNING)
            return
        }
        val error = message["error"] as? JsonObject
        if (error != null) {
            val code = (error["code"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
            val text = (error["message"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: "bridge error"
            continuation.resumeWithException(AcpRemoteError(code, text))
        } else {
            continuation.resume(message["result"] as? JsonObject ?: JsonObject(emptyMap()))
        }
    }

    private fun handleInboundRequest(method: String, id: JsonElement, params: JsonObject) {
        // Its own coroutine: a permission request parks until the user answers, and the frame loop must keep
        // delivering the session updates that the permission's own tool card depends on (I4).
        scope.launch {
            val result = onRequest(method, params)
            if (result != null) {
                send(
                    buildJsonObject {
                        put("jsonrpc", "2.0")
                        put("id", id)
                        put("result", result)
                    },
                )
            } else {
                send(
                    buildJsonObject {
                        put("jsonrpc", "2.0")
                        put("id", id)
                        put(
                            "error",
                            buildJsonObject {
                                put("code", -32601)
                                put("message", "method not found")
                            },
                        )
                    },
                )
            }
        }
    }

    // MARK: - Outbound

    suspend fun request(method: String, params: JsonObject): JsonObject {
        val requestID = synchronized(lock) {
            if (closed) {
                throw AcpRemoteError(null, "not connected to the agent bridge")
            }
            nextRequestID++
        }
        return suspendCancellableCoroutine { continuation ->
            val refused = synchronized(lock) {
                if (closed) {
                    true
                } else {
                    pending[requestID] = continuation
                    false
                }
            }
            if (refused) {
                continuation.resumeWithException(AcpRemoteError(null, "not connected to the agent bridge"))
                return@suspendCancellableCoroutine
            }
            // A cancelled caller must not leave its slot behind: the answer would then resolve nothing and the map
            // would grow for the connection's life. Closing the socket remains the way a watchdog ends a wait (I1),
            // and close() fails every remaining waiter (I2).
            continuation.invokeOnCancellation { synchronized(lock) { pending.remove(requestID) } }
            send(
                buildJsonObject {
                    put("jsonrpc", "2.0")
                    put("id", requestID)
                    put("method", method)
                    put("params", params)
                },
            )
        }
    }

    fun notify(method: String, params: JsonObject) {
        send(
            buildJsonObject {
                put("jsonrpc", "2.0")
                put("method", method)
                put("params", params)
            },
        )
    }

    private fun send(message: JsonObject) {
        val text = runCatching { Json.encodeToString(JsonObject.serializer(), message) }.getOrElse {
            logger.log("acp-remote: refusing to send an unserializable message", ChatLogLevel.ERROR)
            return
        }
        val socket = synchronized(lock) { if (closed) null else socket }
        socket?.send(text)
    }

    /**
     * Closes once and fails every pending request (I2). Idempotent: the socket's own close callback and an explicit
     * close race constantly, and only one of them may notify.
     */
    fun close(error: Throwable? = null) {
        val teardown = synchronized(lock) {
            if (closed) {
                null
            } else {
                closed = true
                val existing = socket
                socket = null
                val waiters = pending.values.toList()
                pending.clear()
                existing to waiters
            }
        } ?: return

        val (existing, waiters) = teardown
        val failure = error ?: AcpRemoteError(null, "the connection to the agent bridge closed")
        for (waiter in waiters) {
            waiter.resumeWithException(failure)
        }
        // 1001 "going away", matching the Swift socket's cancel(with: .goingAway). close() returns false when the
        // socket is already closing or dead, and cancel() is then the only way to release it.
        if (existing != null && !existing.close(1001, null)) {
            existing.cancel()
        }
        onClose(error)
    }

    val isClosed: Boolean
        get() = synchronized(lock) { closed }
}
