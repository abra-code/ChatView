package com.abracode.chatview.acp

// Port of ChatACPRemoteConnectionTests in Tests/ACPTests/ChatACPRemoteTests.swift: request/response correlation,
// concurrent requests, error responses, notifications, an inbound request answered, close-fails-pending exactly
// once, a malformed frame dropped, and a request after close.

import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlinx.coroutines.CoroutineScope

class AcpRemoteConnectionTest {

    private fun connect(
        socket: ScriptedSocket,
        scope: CoroutineScope,
        logger: RecordingLogger = RecordingLogger(),
        onNotification: (String, JsonObject) -> Unit = { _, _ -> },
        onRequest: suspend (String, JsonObject) -> JsonObject? = { _, _ -> null },
        onClose: (Throwable?) -> Unit = {},
    ): AcpRemoteConnection {
        val connection = AcpRemoteConnection(
            logger = logger,
            scope = scope,
            onOpen = {},
            onNotification = onNotification,
            onRequest = onRequest,
            onClose = onClose,
        )
        socket.listener = connection.listener()
        connection.adopt(socket)
        return connection
    }

    @Test
    fun requestResponseCorrelation() = runTest {
        val socket = ScriptedSocket()
        socket.onSend = { s, message ->
            message.element("id")?.let { id ->
                s.deliver(
                    buildJsonObject {
                        put("jsonrpc", "2.0")
                        put("id", id)
                        put("result", buildJsonObject { put("ok", true) })
                    },
                )
            }
        }
        val connection = connect(socket, this)
        val result = connection.request("initialize", JsonObject(emptyMap()))
        assertEquals(true, (result["ok"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toBoolean())
    }

    @Test
    fun concurrentRequestsGetTheirOwnAnswers() = runTest {
        val socket = ScriptedSocket()
        socket.onSend = { s, message ->
            val id = message.element("id")
            val method = message.str("method")
            if (id != null && method != null) {
                s.deliver(
                    buildJsonObject {
                        put("jsonrpc", "2.0")
                        put("id", id)
                        put("result", buildJsonObject { put("echo", method) })
                    },
                )
            }
        }
        val connection = connect(socket, this)
        val first = async { connection.request("alpha", JsonObject(emptyMap())) }
        val second = async { connection.request("beta", JsonObject(emptyMap())) }
        assertEquals("alpha", first.await().str("echo"))
        assertEquals("beta", second.await().str("echo"))
    }

    @Test
    fun errorResponseThrows() = runTest {
        val socket = ScriptedSocket()
        socket.onSend = { s, message ->
            message.element("id")?.let { id ->
                s.deliver(
                    buildJsonObject {
                        put("jsonrpc", "2.0")
                        put("id", id)
                        put(
                            "error",
                            buildJsonObject {
                                put("code", -32001)
                                put("message", "unknown session")
                            },
                        )
                    },
                )
            }
        }
        val connection = connect(socket, this)
        try {
            connection.request("bridge/attach", JsonObject(emptyMap()))
            fail("an error response must throw")
        } catch (error: AcpRemoteError) {
            assertEquals(-32001, error.code)
            assertEquals("unknown session", error.message)
        }
    }

    @Test
    fun notificationsReachTheHandler() = runTest {
        val socket = ScriptedSocket()
        var received = 0
        val connection = connect(socket, this, onNotification = { _, _ -> received += 1 })
        socket.deliver(
            buildJsonObject {
                put("jsonrpc", "2.0")
                put("method", "session/update")
                put("params", buildJsonObject { put("seq", 1) })
            },
        )
        assertEquals(1, received)
        assertFalse(connection.isClosed)
    }

    @Test
    fun inboundRequestIsAnsweredAndUnknownMethodsGetMethodNotFound() = runTest {
        val socket = ScriptedSocket()
        connect(socket, this, onRequest = { method, _ ->
            if (method == "session/request_permission") {
                buildJsonObject { put("outcome", buildJsonObject { put("outcome", "cancelled") }) }
            } else {
                null
            }
        })

        socket.deliver(
            buildJsonObject {
                put("jsonrpc", "2.0")
                put("id", 101)
                put("method", "session/request_permission")
                put("params", JsonObject(emptyMap()))
            },
        )
        socket.deliver(
            buildJsonObject {
                put("jsonrpc", "2.0")
                put("id", 102)
                put("method", "fs/read_text_file")
                put("params", JsonObject(emptyMap()))
            },
        )
        // The handler runs on its own coroutine so the frame loop is never parked; let it drain.
        testScheduler.advanceUntilIdle()

        val answers = socket.sentObjects()
        assertEquals(2, answers.size)
        assertEquals(101, answers[0].num("id"))
        assertNotNull("a handled request gets a result", answers[0]["result"])
        assertEquals(102, answers[1].num("id"))
        assertEquals(
            "an unhandled method gets -32601",
            -32601,
            (answers[1]["error"] as? JsonObject)?.num("code"),
        )
    }

    @Test
    fun closeFailsEveryPendingRequestExactlyOnce() = runTest {
        val socket = ScriptedSocket()
        var closeCount = 0
        val connection = connect(socket, this, onClose = { closeCount += 1 })

        // Never answered; the close is what resolves it (invariant I2). The failure is captured inside the
        // coroutine: an `async` that throws cancels its parent scope in Kotlin, which would take the test with it.
        val pending = async { runCatching { connection.request("initialize", JsonObject(emptyMap())) } }
        testScheduler.advanceUntilIdle()
        connection.close()
        connection.close()

        val error = pending.await().exceptionOrNull()
        assertTrue("a pending request must fail when the connection closes", error is AcpRemoteError)
        assertTrue(error!!.message!!.contains("closed"))
        assertEquals("close must notify exactly once", 1, closeCount)
        assertEquals("the socket is released with 'going away'", 1001, socket.closeCode())
    }

    @Test
    fun socketFailureFailsPendingRequestsWithTheUnderlyingError() = runTest {
        val socket = ScriptedSocket()
        val connection = connect(socket, this)
        val pending = async { runCatching { connection.request("initialize", JsonObject(emptyMap())) } }
        testScheduler.advanceUntilIdle()

        socket.fail(java.io.IOException("network went away"))

        val error = pending.await().exceptionOrNull()
        assertNotNull("a socket failure must fail the pending request", error)
        assertTrue("the underlying failure survives: $error", error!!.message?.contains("network went away") == true)
        assertTrue(connection.isClosed)
    }

    @Test
    fun malformedFrameIsDroppedWithoutCrashing() = runTest {
        val socket = ScriptedSocket()
        val logger = RecordingLogger()
        val connection = connect(socket, this, logger = logger)
        socket.deliverRaw("this is not json")
        socket.deliverRaw("[1,2,3]")
        assertFalse("a bad frame must not tear down a working session", connection.isClosed)
        assertTrue(logger.contains("unparseable"))
    }

    @Test
    fun responseForAnUnknownIdIsLoggedNotFatal() = runTest {
        val socket = ScriptedSocket()
        val logger = RecordingLogger()
        val connection = connect(socket, this, logger = logger)
        socket.deliver(
            buildJsonObject {
                put("jsonrpc", "2.0")
                put("id", 42)
                put("result", JsonObject(emptyMap()))
            },
        )
        assertFalse(connection.isClosed)
        assertTrue(logger.contains("unknown request id 42"))
    }

    @Test
    fun requestAfterCloseThrowsImmediately() = runTest {
        val socket = ScriptedSocket()
        val connection = connect(socket, this)
        connection.close()
        try {
            connection.request("initialize", JsonObject(emptyMap()))
            fail("a request on a closed connection must throw")
        } catch (error: AcpRemoteError) {
            assertTrue(error.message.contains("not connected"))
        }
    }

    @Test
    fun aCancelledRequestLeavesNoPendingSlotBehind() = runTest(StandardTestDispatcher()) {
        val socket = ScriptedSocket()
        val logger = RecordingLogger()
        val connection = connect(socket, this, logger = logger)
        val job = async { connection.request("initialize", JsonObject(emptyMap())) }
        testScheduler.advanceUntilIdle()
        job.cancel()
        testScheduler.advanceUntilIdle()

        // The slot is gone, so a late answer is reported as unknown rather than resolving a stale waiter.
        val id = socket.sentObjects().first().num("id")!!
        socket.deliver(
            buildJsonObject {
                put("jsonrpc", "2.0")
                put("id", id)
                put("result", JsonObject(emptyMap()))
            },
        )
        assertTrue(logger.contains("unknown request id $id"))
    }

    @Test
    fun notifyWritesANotificationFrame() = runTest {
        val socket = ScriptedSocket()
        val connection = connect(socket, this)
        connection.notify("session/cancel", buildJsonObject { put("sessionId", "s1") })
        val frame = socket.sentObjects().single()
        assertEquals("session/cancel", frame.str("method"))
        assertEquals("a notification carries no id", null, frame["id"])
        assertEquals("s1", (frame["params"] as JsonObject).str("sessionId"))
        // Keep the connection referenced so the test reads as a round trip, not a fire-and-forget.
        assertFalse(connection.isClosed)
        delay(0)
    }
}
