package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatTransportRegistryTests.swift.
//
// A registered factory builds its own transport; the reserved `local` name cannot be overridden; the latest
// registration for a name wins. Viability (makeIfViable): an UNREGISTERED name degrades to the built-in `local` (a
// PERMANENT condition), while a REGISTERED factory that throws returns null (NOT viable yet). The registry is a
// singleton with no unregister API, so each test uses a protocol name unique to it to avoid cross-test pollution.

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private val registryTestLogger = object : ChatLogger {
    override fun log(message: String, level: ChatLogLevel) {}
}

/** A stand-in transport a test factory returns, tagged so a test can prove which factory ran. */
private class FakeTransport(val marker: String) : ChatTransport {
    private val channel = Channel<ChatEvent>(Channel.UNLIMITED)
    override val events: ReceiveChannel<ChatEvent> get() = channel
    override suspend fun start() {}
    override suspend fun send(command: ChatCommand) {}
    override suspend fun stop() {
        channel.close()
    }
}

class ChatTransportRegistryTest {

    private val registry get() = ChatTransportRegistry.shared

    private fun makeIfViable(protocolName: String): ChatTransport? =
        registry.makeIfViable(protocolName = protocolName, logger = registryTestLogger)

    private fun requireTransport(protocolName: String): ChatTransport =
        makeIfViable(protocolName) ?: error("expected a viable transport for '$protocolName'")

    @Test
    fun registeredFactoryBuildsItsTransport() {
        registry.register("registry-test-basic") { config, _ -> FakeTransport(marker = "basic:${config.protocolName}") }
        assertEquals(
            "the registered factory should build the transport, and see the resolved protocol name",
            "basic:registry-test-basic",
            (requireTransport("registry-test-basic") as? FakeTransport)?.marker,
        )
    }

    @Test
    fun unregisteredProtocolDegradesToLocal() {
        assertTrue(
            "an unregistered protocol is a permanent condition and must degrade to the built-in local transport",
            requireTransport("registry-test-unregistered-name") is LocalChatTransport,
        )
    }

    @Test
    fun localIsBuiltInWithoutRegistration() {
        assertTrue(requireTransport("local") is LocalChatTransport)
    }

    @Test
    fun localNameIsReservedAndNotOverridable() {
        registry.register("local") { _, _ -> FakeTransport(marker = "hijack") }
        assertTrue(
            "registering 'local' must be ignored; the built-in always wins",
            requireTransport("local") is LocalChatTransport,
        )
    }

    @Test
    fun lastRegistrationWins() {
        registry.register("registry-test-override") { _, _ -> FakeTransport(marker = "first") }
        registry.register("registry-test-override") { _, _ -> FakeTransport(marker = "second") }
        assertEquals("second", (requireTransport("registry-test-override") as? FakeTransport)?.marker)
    }

    @Test
    fun emptyNameIsIgnored() {
        registry.register("") { _, _ -> FakeTransport(marker = "empty") }
        assertFalse(registry.isRegistered(""))
    }

    @Test
    fun throwingFactoryIsNotViable() {
        registry.register("registry-test-throws") { _, _ -> throw RuntimeException("not ready") }
        assertNull(
            "a registered factory that throws is not viable yet - makeIfViable returns null so the element stays deferred (it does NOT degrade to local)",
            makeIfViable("registry-test-throws"),
        )
    }

    @Test
    fun isRegistered() {
        assertTrue("the built-in local is always registered", registry.isRegistered("local"))
        assertFalse(registry.isRegistered("registry-test-never-registered"))
        registry.register("registry-test-present") { _, _ -> FakeTransport(marker = "present") }
        assertTrue(registry.isRegistered("registry-test-present"))
    }
}
