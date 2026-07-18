package com.abracode.chatview

// Port of Sources/ChatView/ChatTransportRegistry.swift.
//
// The transport registry: the table mapping a protocol name to the factory that builds its transport. `local` is
// reserved (it cannot be overridden) and `local-p2p` is seeded at init (a built-in a host may still override). Every
// other protocol is a separate module that registers a factory through its register() entry point.
//
// The component resolves its transport through makeIfViable when the chat starts: a registered name builds via its
// factory (a throwing factory returns nil - NOT viable yet, the deferred-config element waits); an unregistered
// name degrades to `local` with a warning (a PERMANENT condition). Main-confined, like element registration.

import kotlinx.serialization.json.JsonObject

class ChatTransportRegistry private constructor() {

    /** Logger for registration-time diagnostics. Hosts may replace it; defaults to the console. */
    var logger: ChatLogger = ConsoleChatLogger()

    // Swift confines the registry to @MainActor. Kotlin has no such structural guarantee here, so the factory map is
    // guarded by a lock: registration is meant to happen at launch, but a stray off-thread register() must not race
    // makeIfViable into a corrupt map.
    private val lock = Any()
    private val factories = mutableMapOf<String, ChatTransportFactory>()

    init {
        // The scripted person-to-person / group backend, a built-in like `local` but registered (not reserved) so a
        // host can still override the name. Seeded here so the component works standalone.
        factories["local-p2p"] = ChatTransportFactory { config, _ -> LocalP2PTransport(config) }
    }

    /**
     * Registers a factory under a protocol name. Last registration wins (logged). The reserved name `local` and the
     * empty string are rejected. Main-confined - call at launch, before any chat view is built.
     */
    fun register(name: String, factory: ChatTransportFactory) {
        if (name == reservedLocalName) {
            logger.log(
                "Chat: transport name 'local' is reserved (the built-in transport); ignoring registration",
                ChatLogLevel.WARNING,
            )
            return
        }
        if (name.isEmpty()) {
            logger.log("Chat: a transport name must be non-empty; ignoring registration", ChatLogLevel.WARNING)
            return
        }
        val existed = synchronized(lock) {
            val present = factories[name] != null
            factories[name] = factory
            present
        }
        if (existed) {
            logger.log("Chat: transport '$name' re-registered; the latest registration wins", ChatLogLevel.INFO)
        }
    }

    /** Whether a protocol name resolves to a transport (the reserved `local`, or a registered factory). */
    fun isRegistered(name: String): Boolean =
        name == reservedLocalName || synchronized(lock) { factories[name] != null }

    /**
     * Builds the transport for a host-injected config, if it is VIABLE right now. Returns null when a REGISTERED
     * protocol's factory throws (a transient "config not complete yet" state - the deferred-config chat stays inert
     * and waits). `local` (built in) and an UNREGISTERED name both yield a transport - an unregistered name is a
     * PERMANENT condition, so it degrades to `local` with a warning rather than blocking the chat forever.
     */
    fun makeIfViable(
        protocolName: String,
        transport: JsonObject = JsonObject(emptyMap()),
        logger: ChatLogger,
    ): ChatTransport? {
        val transportConfig = ChatTransportConfig(protocolName = protocolName, settings = transport)

        if (protocolName == reservedLocalName) {
            return LocalChatTransport(transportConfig, logger)
        }

        val factory = synchronized(lock) { factories[protocolName] }
        if (factory == null) {
            logger.log(
                "Chat transport '$protocolName' is not registered (link its module and call its register()); using 'local'",
                ChatLogLevel.WARNING,
            )
            return LocalChatTransport(transportConfig, logger)
        }

        return try {
            factory.create(transportConfig, logger)
        } catch (error: Throwable) {
            logger.log(
                "Chat transport '$protocolName' not viable yet ($error); awaiting a complete config",
                ChatLogLevel.VERBOSE,
            )
            null
        }
    }

    companion object {
        val shared = ChatTransportRegistry()

        /** The reserved built-in protocol name. Always available, never overridable. */
        const val reservedLocalName = "local"
    }
}
