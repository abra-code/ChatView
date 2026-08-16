package com.abracode.chatview.acp

// Port of the transport half of Tests/ACPTests/ChatACPRemoteTests.swift (plan items 3.4 / 2.2 / 2.2a). Same
// scenarios, same names camelCased, same assertions - the two suites are meant to be diffable, so a behavior that
// drifts on one platform shows up as a test that exists only on the other.
//
// The bridge these tests talk to is ScriptedBridge in TestSupport.kt, written from the wire spec (plan section 7)
// rather than from the Swift bridge, which is what makes it a conformance check rather than a mirror.

import com.abracode.chatview.ChatCommand
import com.abracode.chatview.ChatTransportConfig
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AcpRemoteTransportTest {

    private class Harness(
        val transport: AcpRemoteTransport,
        val factory: ScriptedSocketFactory,
        val collector: EventCollector,
        val logger: RecordingLogger,
    )

    private fun makeTransport(
        settings: Map<String, Any?> = emptyMap(),
        bridge: ScriptedBridge,
        logger: RecordingLogger = RecordingLogger(),
        configure: ((Int, ScriptedSocket) -> Unit)? = null,
    ): Harness {
        val merged = buildJsonObject {
            put("url", "ws://127.0.0.1:8737/acp")
            put("token", "T")
            for ((key, value) in settings) {
                when (value) {
                    is String -> put(key, value)
                    is Int -> put(key, value)
                    is Double -> put(key, value)
                    is Boolean -> put(key, value)
                    else -> Unit
                }
            }
        }
        val factory = ScriptedSocketFactory { index, socket ->
            bridge.attachTo(socket)
            configure?.invoke(index, socket)
        }
        val transport = AcpRemoteTransport(
            config = ChatTransportConfig(protocolName = "acp-remote", settings = merged),
            logger = logger,
            webSocketFactory = factory,
        )
        val collector = EventCollector()
        collector.start(transport)
        return Harness(transport, factory, collector, logger)
    }

    /** Releases a harness built for a construction-only check: an unstopped transport leaks its channel + scope. */
    private fun Harness.close() = runBlocking {
        transport.stop()
        collector.stop()
    }

    private fun agentChunk(text: String): JsonObject = buildJsonObject {
        putJsonObject("update") {
            put("sessionUpdate", "agent_message_chunk")
            putJsonObject("content") {
                put("type", "text")
                put("text", text)
            }
        }
    }

    private fun permissionRequestFrame(id: Int, requestKey: String = "perm-1"): JsonObject = buildJsonObject {
        put("jsonrpc", "2.0")
        put("id", id)
        put("method", "session/request_permission")
        putJsonObject("params") {
            put("sessionId", "sess-1")
            put("requestKey", requestKey)
            putJsonObject("toolCall") {
                put("toolCallId", "call-1")
                put("title", "Edit main.kt")
            }
            putJsonArray("options") {
                add(
                    buildJsonObject {
                        put("optionId", "allow")
                        put("name", "Allow")
                        put("kind", "allow_once")
                    },
                )
                add(
                    buildJsonObject {
                        put("optionId", "deny")
                        put("name", "Deny")
                        put("kind", "reject_once")
                    },
                )
            }
        }
    }

    // MARK: - Config validation

    @Test(expected = AcpRemoteError::class)
    fun config_missingUrlThrows() {
        AcpRemoteTransport(ChatTransportConfig(settings = JsonObject(emptyMap())), RecordingLogger())
    }

    @Test
    fun config_insecureUrlPolicy() {
        fun make(vararg pairs: Pair<String, Any>): Result<AcpRemoteTransport> = runCatching {
            val settings = buildJsonObject {
                for ((key, value) in pairs) {
                    when (value) {
                        is String -> put(key, value)
                        is Boolean -> put(key, value)
                        else -> Unit
                    }
                }
            }
            AcpRemoteTransport(ChatTransportConfig(settings = settings), RecordingLogger())
        }

        // A token that is remote code execution must not go over cleartext to a public host.
        assertTrue("cleartext to a public host must be refused", make("url" to "ws://public.example/acp").isFailure)
        assertTrue(make("url" to "ws://192.168.1.10:8737/acp").isSuccess)
        assertTrue(make("url" to "ws://mac.local:8737/acp").isSuccess)
        assertTrue("Tailscale CGNAT is a private network", make("url" to "ws://100.72.1.4:8737/acp").isSuccess)
        assertTrue(make("url" to "wss://public.example/acp").isSuccess)
        assertTrue(make("url" to "ws://public.example/acp", "allowInsecure" to true).isSuccess)
        assertTrue("only ws/wss are transports here", make("url" to "http://mac.local/acp").isFailure)
        // A bracketed IPv6 literal is a perfectly ordinary loopback bridge address, and the gate runs on the host
        // the socket will actually be opened with - so it must see `::1`, not `[::1]`.
        assertTrue(make("url" to "ws://[::1]:8737/acp").isSuccess)
        assertTrue(make("url" to "ws://[fd00::5]:8737/acp").isSuccess)
        assertTrue("a public IPv6 host over cleartext is still refused", make("url" to "ws://[2606:4700::1]/acp").isFailure)
        // Rejected by the parser that will connect it, at construction, rather than thrown out of start().
        assertTrue("a port no URL can carry", make("url" to "ws://127.0.0.1:99999/acp").isFailure)
        assertTrue(make("url" to "not a url at all").isFailure)
    }

    @Test
    fun config_spoofedHostsAreRefusedByTheFactory() {
        // The factory is the gate that matters: isPrivateHost is only as good as the value it is handed, and these
        // are the names that read as private to a sloppy parser.
        fun build(raw: String) = runCatching {
            AcpRemoteTransport(
                ChatTransportConfig(settings = buildJsonObject { put("url", raw) }),
                RecordingLogger(),
            )
        }

        for (raw in listOf(
            "ws://127.0.0.1.evil.com/acp",
            "ws://10.0.0.1.example.com/acp",
            // Percent-encoded dot: the host OkHttp resolves is 127.0.0.1.evil.com, an address an attacker owns.
            "ws://127.0.0.1%2eevil.com/acp",
        )) {
            assertTrue("$raw must not get the token onto cleartext", build(raw).isFailure)
        }

        // Userinfo, by contrast, is ALLOWED - and that is the point of validating the URL that will be dialed
        // rather than a separately parsed copy. Whatever sits before the last '@', the socket opens to 127.0.0.1.
        assertTrue(
            "a loopback host is loopback however the authority is written",
            build("ws://a@b@127.0.0.1/acp").isSuccess,
        )
    }

    @Test
    fun config_privateHostClassification() {
        for (host in listOf(
            "127.0.0.1", "localhost", "mac.local", "10.0.0.5", "192.168.1.2",
            "172.16.0.1", "172.31.255.255", "169.254.1.1", "100.64.0.1",
        )) {
            assertTrue("$host should be private", AcpRemoteTransport.isPrivateHost(host))
        }
        // IPv6 and the trailing root dot, matching the Swift suite case for case.
        for (host in listOf("::1", "fd00::1", "fe80::1%en0", "127.0.0.1.", "mac.local.")) {
            assertTrue("$host should be private", AcpRemoteTransport.isPrivateHost(host))
        }
        for (host in listOf("example.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", "", "2606:4700::1")) {
            assertFalse("$host should NOT be private", AcpRemoteTransport.isPrivateHost(host))
        }
        // The spoofing cases the gate exists for: an attacker who registers these names must not be handed the
        // token over plain ws://. It fails CLOSED - every label must parse, or the host is public.
        for (host in listOf(
            "127.0.0.1.evil.com", "0177.0.0.1", "10.0.0.1.example.com", "10.0.0", "999.1.1.1",
            "10.0.0.1.2", "127.0.0.01", "10.0.0.256", "192.168.1.evil", "a.10.b.0.c.0.d.1.evil.com",
        )) {
            assertFalse("$host must not read as private", AcpRemoteTransport.isPrivateHost(host))
        }
    }

    @Test
    fun config_handshakeTimeoutDefaultAndClamping() {
        val bridge = ScriptedBridge()
        val defaulted = makeTransport(bridge = bridge)
        assertEquals(15.0, defaulted.transport.handshakeTimeout, 0.001)
        defaulted.close()

        val none = makeTransport(settings = mapOf("handshakeTimeoutSeconds" to 0), bridge = bridge)
        assertEquals("0 means no watchdog", 0.0, none.transport.handshakeTimeout, 0.001)
        none.close()

        val absurd = makeTransport(settings = mapOf("handshakeTimeoutSeconds" to 1e18), bridge = bridge)
        assertEquals("a nonsense value must clamp, not overflow", 86_400.0, absurd.transport.handshakeTimeout, 0.001)
        absurd.close()
    }

    // MARK: - Connect

    @Test
    fun connect_newSessionEmitsReadyAndInfo() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(settings = mapOf("session" to "new"), bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }

        assertEquals(
            "I6: the session is announced before anything else can arrive",
            listOf("state:connecting", "ready:sess-1", "info:sess-1:resumed=false", "state:connected"),
            h.collector.log().take(4),
        )
        h.transport.stop()
    }

    @Test
    fun connect_sessionInfoCarriesTheAgentIdentityFromTheBridge() = runBlocking {
        val h = makeTransport(bridge = ScriptedBridge())
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }

        val info = h.collector.events().filterIsInstance<com.abracode.chatview.ChatEvent.SessionInfo>().first().info
        assertEquals("a phone has no other way to learn what agent it is talking to", "scripted-agent", info.agentName)
        assertEquals("9.9", info.agentVersion)
        assertNull("the agent's pid is a fact about the bridge host, not this client", info.agentPid)
        h.transport.stop()
    }

    @Test
    fun connect_tokenTravelsInBandAndAsABearerHeader() = runBlocking {
        val h = makeTransport(bridge = ScriptedBridge())
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }

        val socket = h.factory.socket(0)!!
        assertEquals("Bearer T", socket.upgradeRequest?.header("Authorization"))
        val initialize = socket.frames("initialize").first()["params"]!!.jsonObject
        assertEquals("the bridge validates the in-band copy", "T", initialize.str("bridgeToken"))
        h.transport.stop()
    }

    @Test
    fun connect_handshakeWatchdogClosesTheSocket() = runBlocking {
        // A socket that never answers anything: the watchdog must close it rather than hang.
        val h = makeTransport(
            settings = mapOf("handshakeTimeoutSeconds" to 0.3),
            bridge = ScriptedBridge(),
            configure = { _, socket -> socket.onSend = { _, _ -> } },
        )
        h.transport.start()
        h.collector.waitFor("the watchdog to fire", timeoutMs = 5_000) {
            h.collector.log().any { it.startsWith("error:false:") }
        }
        assertTrue(
            "I1: the watchdog closes the SOCKET; racing the request against a timeout deadlocks",
            h.factory.socket(0)?.isClosed() == true,
        )
        h.transport.stop()
    }

    @Test
    fun connect_healthyConnectionSurvivesPastTheHandshakeTimeout() = runBlocking {
        val h = makeTransport(settings = mapOf("handshakeTimeoutSeconds" to 0.3), bridge = ScriptedBridge())
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }

        // I1's other half: the watchdog must be RETIRED on success. Without that it closes every healthy
        // connection once the timeout elapses, which in production looks like the agent dropping the user
        // mid-conversation.
        delay(700)
        assertFalse(
            "a connection that handshook successfully must not be closed by its watchdog",
            h.factory.socket(0)?.isClosed() ?: true,
        )
        assertFalse(h.collector.log().contains("state:reconnecting"))
        h.transport.stop()
    }

    // MARK: - Turn demux

    @Test
    fun turn_promptMapsToEvents() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        h.transport.send(ChatCommand.Prompt("hello"))
        h.collector.waitFor("the prompt to reach the wire") { socket.frames("session/prompt").isNotEmpty() }
        val echoKey = socket.frames("session/prompt").first()["params"]!!.jsonObject.str("echoKey")!!

        // Our own user message comes back and must NOT be rendered again.
        bridge.push(
            socket,
            "bridge/user_message",
            buildJsonObject {
                put("turn", 1)
                put("echoKey", echoKey)
                putJsonArray("content") {
                    add(
                        buildJsonObject {
                            put("type", "text")
                            put("text", "hello")
                        },
                    )
                }
            },
        )
        bridge.push(socket, "session/update", agentChunk("Hi "))
        bridge.push(socket, "session/update", agentChunk("there."))
        bridge.push(
            socket,
            "bridge/turn_ended",
            buildJsonObject {
                put("turn", 1)
                put("stopReason", "end_turn")
            },
        )

        h.collector.waitFor("the turn to close") { h.collector.log().any { it.startsWith("end:") } }
        val log = h.collector.log()
        assertFalse(
            "our own echo must be suppressed - the store already appended it",
            log.any { it.startsWith("start:") && it.endsWith(":local") },
        )
        assertTrue("ids derive from seq; saw $log", log.contains("start:acpr-m-2:agent"))
        assertTrue(log.contains("delta:acpr-m-2:Hi "))
        assertTrue("a second chunk extends the same bubble", log.contains("delta:acpr-m-2:there."))
        assertTrue(log.contains("end:acpr-m-2:end_turn"))
        h.transport.stop()
    }

    @Test
    fun turn_anotherDevicesUserMessageIsRendered() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        // An echoKey we never minted: somebody else typed this.
        bridge.push(
            socket,
            "bridge/user_message",
            buildJsonObject {
                put("turn", 1)
                put("echoKey", "someone-else")
                putJsonArray("content") {
                    add(
                        buildJsonObject {
                            put("type", "text")
                            put("text", "from the laptop")
                        },
                    )
                }
            },
        )
        h.collector.waitFor("the other device's message") {
            h.collector.log().any { it.startsWith("delta:") && it.endsWith("from the laptop") }
        }
        assertTrue(h.collector.log().contains("start:acpr-m-1:local"))
        h.transport.stop()
    }

    @Test
    fun turn_endWithNoOpenBubbleStillCloses() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        bridge.push(
            socket,
            "bridge/turn_ended",
            buildJsonObject {
                put("turn", 1)
                put("stopReason", "cancelled")
            },
        )
        // Without this the store's streaming flag never clears and the composer stays disabled.
        h.collector.waitFor("a terminal messageEnd") { h.collector.log().contains("end:acpr-turn-1:cancelled") }
        h.transport.stop()
    }

    @Test
    fun turn_thoughtsSegmentSeparatelyFromMessages() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        bridge.push(
            socket,
            "session/update",
            buildJsonObject {
                putJsonObject("update") {
                    put("sessionUpdate", "agent_thought_chunk")
                    putJsonObject("content") {
                        put("type", "text")
                        put("text", "thinking")
                    }
                }
            },
        )
        bridge.push(socket, "session/update", agentChunk("answer"))

        h.collector.waitFor("both items") { h.collector.log().any { it.startsWith("delta:acpr-m-2") } }
        assertTrue(h.collector.log().contains("thought:acpr-t-1:thinking"))
        h.transport.stop()
    }

    @Test
    fun turn_roleSwitchClosesThePreviousBubble() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        bridge.push(socket, "session/update", agentChunk("from the agent"))
        bridge.push(
            socket,
            "session/update",
            buildJsonObject {
                putJsonObject("update") {
                    put("sessionUpdate", "user_message_chunk")
                    putJsonObject("content") {
                        put("type", "text")
                        put("text", "from a person")
                    }
                }
            },
        )

        h.collector.waitFor("both bubbles") { h.collector.log().any { it.startsWith("start:acpr-m-2") } }
        // Without the close, the first bubble stays streaming until the turn ends - and the turn-end only closes
        // the newest id, so it never closes at all.
        assertTrue(
            "a role switch must close the bubble it replaces; saw ${h.collector.log()}",
            h.collector.log().contains("end:acpr-m-1:-"),
        )
        h.transport.stop()
    }

    @Test
    fun turn_duplicateSeqsAreIgnored() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        bridge.pushAt(socket, 1, "session/update", agentChunk("once"))
        h.collector.waitFor("the first delivery") { h.collector.log().any { it.endsWith(":once") } }
        // At-least-once delivery plus idempotent processing (I7): re-delivery must be a no-op.
        bridge.pushAt(socket, 1, "session/update", agentChunk("once"))
        delay(100)
        assertEquals(
            "a seq at or below lastSeq must be dropped",
            1,
            h.collector.log().count { it.endsWith(":once") },
        )
        h.transport.stop()
    }

    // MARK: - Reconnect and resume

    @Test
    fun reconnect_attachesFromLastSeq() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val first = h.factory.socket(0)!!

        bridge.push(first, "session/update", agentChunk("before"))
        h.collector.waitFor("the first chunk") { h.collector.log().any { it.endsWith(":before") } }

        bridge.latestSeqAtAttach = 3
        bridge.replayOnAttach = listOf(
            "session/update" to bridge.replayEntry(2, agentChunk("missed")),
            "bridge/turn_ended" to bridge.replayEntry(
                3,
                buildJsonObject {
                    put("turn", 1)
                    put("stopReason", "end_turn")
                },
            ),
        )
        first.dropConnection()

        h.collector.waitFor("reconnect and replay", timeoutMs = 10_000) {
            h.collector.log().any { it.endsWith(":missed") }
        }
        assertEquals("the reattach must resume from lastSeq, not from 0", 1, bridge.attachCursor())
        assertTrue(h.collector.log().contains("state:reconnecting"))
        // I9: the drop itself must NOT have ended the turn - only the replayed turn_ended does.
        h.collector.waitFor("the replayed turn end", timeoutMs = 10_000) {
            h.collector.log().any { it.startsWith("end:") }
        }
        val log = h.collector.log()
        val endIndex = log.indexOfFirst { it.startsWith("end:") }
        val missedIndex = log.indexOfFirst { it.endsWith(":missed") }
        assertTrue("the replayed chunk must have been rendered", missedIndex >= 0)
        assertTrue(
            "the turn must end from the replay, never from the socket dropping",
            missedIndex < endIndex,
        )
        h.transport.stop()
    }

    @Test
    fun reconnect_endedSessionSurfacesANonRecoverableError() = runBlocking {
        val bridge = ScriptedBridge(sessionID = "sess-old")
        bridge.stateAtAttach = "ended"
        val h = makeTransport(settings = mapOf("session" to "sess-old"), bridge = bridge)
        h.transport.start()
        h.collector.waitFor("the ended notice") { h.collector.log().any { it.startsWith("error:false:") } }
        // The transcript still replays; the error only says it cannot be continued.
        assertTrue(h.collector.log().contains("ready:sess-old"))
        assertTrue(h.collector.log().any { it.contains("has ended") })
        h.transport.stop()
    }

    @Test
    fun reconnect_promptWhileDisconnectedErrorsAndDoesNotQueue() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        h.factory.socket(0)!!.dropConnection()

        h.transport.send(ChatCommand.Prompt("into the void"))
        h.collector.waitFor("a recoverable error") { h.collector.log().any { it.startsWith("error:true:") } }
        assertTrue(
            "a queued prompt firing minutes later would surprise the user",
            h.collector.log().any { it.contains("not sent") },
        )
        h.transport.stop()
    }

    @Test
    fun reconnect_nonRecoverableRefusalStopsReconnecting() = runBlocking {
        val h = makeTransport(
            bridge = ScriptedBridge(),
            configure = { _, socket ->
                socket.onSend = { sending, message ->
                    val id = message.element("id")
                    if (id != null) {
                        sending.deliver(
                            buildJsonObject {
                                put("jsonrpc", "2.0")
                                put("id", id)
                                putJsonObject("error") {
                                    put("code", -32000)
                                    put("message", "authentication failed")
                                }
                            },
                        )
                    }
                }
            },
        )
        h.transport.start()
        h.collector.waitFor("the refusal") { h.collector.log().any { it.startsWith("error:false:") } }

        // Retrying a bad token forever helps nobody and hammers the bridge.
        delay(1_500)
        assertFalse(
            "a refusal retrying cannot fix must not start the reconnect loop; saw ${h.collector.log()}",
            h.collector.log().contains("state:reconnecting"),
        )
        assertEquals("no second attempt should have been made", 1, h.factory.sockets().size)
        h.transport.stop()
    }

    @Test
    fun reconnect_cancelWhileDisconnectedLatchesUntilReattach() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val first = h.factory.socket(0)!!

        h.transport.send(ChatCommand.Prompt("long running"))
        h.collector.waitFor("the prompt") { first.frames("session/prompt").isNotEmpty() }

        // The turn is still running bridge-side; the bridge reports it at reattach.
        bridge.activeTurnAtAttach = 1
        bridge.latestSeqAtAttach = 0
        first.dropConnection()
        h.transport.send(ChatCommand.Cancel)

        h.collector.waitFor("the reconnect", timeoutMs = 10_000) { h.factory.sockets().size > 1 }
        val second = h.factory.socket(1)!!
        // I3: Stop must still stop, even when it was pressed with no connection.
        h.collector.waitFor("the latched cancel to reach the wire", timeoutMs = 10_000) {
            second.frames("session/cancel").isNotEmpty()
        }
        h.transport.stop()
    }

    @Test
    fun reconnect_cancelIsNotSentForATurnThatAlreadyEnded() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val first = h.factory.socket(0)!!
        h.transport.send(ChatCommand.Prompt("quick"))
        h.collector.waitFor("the prompt") { first.frames("session/prompt").isNotEmpty() }

        // The bridge says no turn is running when we come back: the latch must NOT fire, or we would cancel
        // whatever turn starts next.
        bridge.activeTurnAtAttach = null
        first.dropConnection()
        h.transport.send(ChatCommand.Cancel)

        h.collector.waitFor("the reconnect", timeoutMs = 10_000) { h.factory.sockets().size > 1 }
        delay(300)
        assertTrue(
            "a latched cancel must target its own turn, not the next one",
            h.factory.socket(1)!!.frames("session/cancel").isEmpty(),
        )
        h.transport.stop()
    }

    // MARK: - Permissions

    @Test
    fun permission_roundTrip() = runBlocking {
        val h = makeTransport(bridge = ScriptedBridge())
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        socket.deliver(permissionRequestFrame(900))
        // The id IS the requestKey, so the gate survives a reconnect and matches other devices.
        h.collector.waitFor("the gate") { h.collector.log().contains("perm:perm-1") }

        h.transport.send(ChatCommand.PermissionResponse("perm-1", "allow"))
        h.collector.waitFor("the answer on the wire") { socket.results().isNotEmpty() }
        val outcome = socket.results().first()["result"]!!.jsonObject["outcome"]!!.jsonObject
        assertEquals("selected", outcome.str("outcome"))
        assertEquals("allow", outcome.str("optionId"))
        h.transport.stop()
    }

    @Test
    fun permission_resolvedElsewhereClearsTheGate() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        socket.deliver(permissionRequestFrame(900))
        h.collector.waitFor("the gate") { h.collector.log().contains("perm:perm-1") }

        // Another device answered it. We must clear our gate without answering ourselves.
        bridge.push(
            socket,
            "bridge/permission_resolved",
            buildJsonObject {
                put("requestKey", "perm-1")
                put("outcome", "selected")
                put("optionId", "allow")
            },
        )
        h.collector.waitFor("the resolution") { h.collector.log().contains("permresolved:perm-1") }
        assertFalse(
            "a resolution elsewhere is not a timeout, so no notice belongs in the transcript",
            h.collector.log().any { it.startsWith("system:") },
        )
        h.transport.stop()
    }

    @Test
    fun permission_timeoutAlsoEmitsASystemNotice() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        socket.deliver(permissionRequestFrame(900))
        h.collector.waitFor("the gate") { h.collector.log().contains("perm:perm-1") }

        bridge.push(
            socket,
            "bridge/permission_resolved",
            buildJsonObject {
                put("requestKey", "perm-1")
                put("outcome", "timeout")
                put("optionId", "deny")
            },
        )
        // What a returning user sees instead of a stale prompt.
        h.collector.waitFor("the timeout notice") {
            h.collector.log().any { it.startsWith("system:") && it.contains("timed out") }
        }
        assertTrue(h.collector.log().contains("permresolved:perm-1"))
        h.transport.stop()
    }

    @Test
    fun permission_answeredWhileDisconnectedSurvivesTheReattach() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val first = h.factory.socket(0)!!

        first.deliver(permissionRequestFrame(900))
        h.collector.waitFor("the gate") { h.collector.log().contains("perm:perm-1") }

        // The socket dies, THEN the user taps Allow. The answer must not evaporate.
        first.dropConnection()
        h.transport.send(ChatCommand.PermissionResponse("perm-1", "allow"))

        h.collector.waitFor("the reconnect", timeoutMs = 10_000) { h.factory.sockets().size > 1 }
        val second = h.factory.socket(1)!!
        second.deliver(permissionRequestFrame(901))

        h.collector.waitFor("the held answer to be applied", timeoutMs = 10_000) { second.results().isNotEmpty() }
        val outcome = second.results().first()["result"]!!.jsonObject["outcome"]!!.jsonObject
        assertEquals("the user answered once; they must not be asked again", "allow", outcome.str("optionId"))
        assertEquals(
            "and the gate must not be shown a second time",
            1,
            h.collector.log().count { it == "perm:perm-1" },
        )
        h.transport.stop()
    }

    @Test
    fun permission_reissuedDoesNotStackASecondGate() = runBlocking {
        val h = makeTransport(bridge = ScriptedBridge())
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        socket.deliver(permissionRequestFrame(900))
        h.collector.waitFor("the gate") { h.collector.log().contains("perm:perm-1") }
        // A second re-issue of the SAME key, which the bridge does for every attaching client.
        socket.deliver(permissionRequestFrame(901))
        delay(200)

        assertEquals(
            "the store appends gates without deduping, so a re-issue must not emit again",
            1,
            h.collector.log().count { it == "perm:perm-1" },
        )

        // Both parked requests must be answered - neither may be left waiting forever.
        h.transport.send(ChatCommand.PermissionResponse("perm-1", "allow"))
        h.collector.waitFor("both requests answered") { socket.results().size == 2 }
        h.transport.stop()
    }

    // MARK: - Cold-launch checkpoint (plan 4.2a)

    @Test
    fun checkpoint_emittedAtTurnBoundaryOnly() = runBlocking {
        val bridge = ScriptedBridge()
        val h = makeTransport(bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        val socket = h.factory.socket(0)!!

        bridge.push(socket, "session/update", agentChunk("streaming"))
        delay(80)
        assertFalse(
            "a mid-stream checkpoint would pair a cursor with a half-rendered bubble",
            h.collector.log().any { it.startsWith("checkpoint:") },
        )

        bridge.push(
            socket,
            "bridge/turn_ended",
            buildJsonObject {
                put("turn", 1)
                put("stopReason", "end_turn")
            },
        )
        h.collector.waitFor("the checkpoint") { h.collector.log().any { it.startsWith("checkpoint:") } }
        assertEquals(
            "exactly one checkpoint, carrying the turn_ended seq",
            listOf("checkpoint:sess-1:2"),
            h.collector.log().filter { it.startsWith("checkpoint:") },
        )
        h.transport.stop()
    }

    @Test
    fun checkpoint_afterAQuietAttach() = runBlocking {
        val bridge = ScriptedBridge()
        bridge.latestSeqAtAttach = 5
        val h = makeTransport(settings = mapOf("session" to "sess-1", "resumeAfterSeq" to 5), bridge = bridge)
        h.transport.start()
        h.collector.waitFor("the checkpoint") { h.collector.log().any { it.startsWith("checkpoint:") } }
        assertTrue(
            "a settled attach with no live turn is a checkpoint moment",
            h.collector.log().contains("checkpoint:sess-1:5"),
        )
        h.transport.stop()
    }

    @Test
    fun checkpoint_quietAttachWaitsForTheReplayToLand() = runBlocking {
        // The attach RESULT arrives before the notifications it announces, so a checkpoint fired on the result
        // would hand the host a cursor describing the state before the catch-up it is about to render. The
        // transport arms a target instead and fires when lastSeq reaches the tail the bridge named.
        val bridge = ScriptedBridge()
        bridge.latestSeqAtAttach = 7
        bridge.replayOnAttach = listOf("session/update" to bridge.replayEntry(7, agentChunk("caught up")))
        val h = makeTransport(settings = mapOf("session" to "sess-1", "resumeAfterSeq" to 5), bridge = bridge)
        h.transport.start()

        h.collector.waitFor("the checkpoint") { h.collector.log().any { it.startsWith("checkpoint:") } }
        val log = h.collector.log()
        assertEquals(
            "the cursor must describe the replayed tail, not the cursor we attached with",
            listOf("checkpoint:sess-1:7"),
            log.filter { it.startsWith("checkpoint:") },
        )
        val replayedIndex = log.indexOfFirst { it.endsWith(":caught up") }
        assertTrue("the replayed entry must have been rendered", replayedIndex >= 0)
        assertTrue(
            "and the checkpoint must land after it, not before",
            replayedIndex < log.indexOfFirst { it.startsWith("checkpoint:") },
        )
        h.transport.stop()
    }

    @Test
    fun checkpoint_resumeAfterSeqIsSentOnTheFirstAttach() = runBlocking {
        val bridge = ScriptedBridge()
        bridge.latestSeqAtAttach = 412
        val h = makeTransport(settings = mapOf("session" to "sess-1", "resumeAfterSeq" to 412), bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        assertEquals(
            "the whole point of the checkpoint: ask only for what came after it",
            412,
            bridge.attachCursor(),
        )
        h.transport.stop()
    }

    @Test
    fun checkpoint_resumeAfterSeqIgnoredForNewOrLatestSession() {
        val h = makeTransport(
            settings = mapOf("session" to "new", "resumeAfterSeq" to 99),
            bridge = ScriptedBridge(),
        )
        h.close()
        assertTrue(
            "a cursor is only meaningful against the session id it was minted for",
            h.logger.contains("ignoring resumeAfterSeq"),
        )
    }

    @Test
    fun checkpoint_resumeAfterSeqIgnoredOnSessionMismatch() = runBlocking {
        val bridge = ScriptedBridge(sessionID = "sess-1")
        bridge.attachSessionIDOverride = "sess-DIFFERENT"
        bridge.latestSeqAtAttach = 50
        val h = makeTransport(settings = mapOf("session" to "sess-1", "resumeAfterSeq" to 40), bridge = bridge)
        h.transport.start()
        h.collector.waitFor("connected") { h.collector.log().contains("state:connected") }
        assertTrue(
            "a cursor from another session would silently skip this session's history",
            h.logger.contains("replaying from the beginning"),
        )
        assertEquals("and the second attach must ask for everything", 0, bridge.attachCursor())
        h.transport.stop()
    }

    // MARK: - Registration

    @Test
    fun registration_registersTheProtocolName() {
        ChatViewAcpRemote.register()
        assertTrue(
            "a host links the module and calls register(); the document then names the protocol",
            com.abracode.chatview.ChatTransportRegistry.shared.isRegistered("acp-remote"),
        )
        assertNotNull(
            "and a complete config must build a transport",
            com.abracode.chatview.ChatTransportRegistry.shared.makeIfViable(
                "acp-remote",
                buildJsonObject { put("url", "wss://mac.example:8737/acp") },
                RecordingLogger(),
            ),
        )
        assertNull(
            "while an incomplete one leaves the element deferred rather than degrading it to local",
            com.abracode.chatview.ChatTransportRegistry.shared.makeIfViable(
                "acp-remote",
                JsonObject(emptyMap()),
                RecordingLogger(),
            ),
        )
    }
}
