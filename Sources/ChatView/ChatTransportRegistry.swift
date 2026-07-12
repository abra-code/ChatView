// Sources/ChatView/ChatTransportRegistry.swift
//
// The transport registry: the main-actor table mapping a protocol name to the factory
// that builds its transport. `local` is reserved (it cannot be overridden) and `local-p2p`
// is seeded at init (a built-in a host may still override). Every other protocol - ACP,
// OpenAI SSE, a host's own - is a separate statically linked module that registers a
// factory through its register() entry point; the strong reference from that register()
// call is exactly what makes the linker extract the module's archive member, so "did the
// host link it" and "is it registered" are the same fact by construction.
//
// The component resolves its transport through `makeIfViable` when the chat starts: a
// registered name builds via its factory (a throwing factory degrades to `local` with a
// logged reason); an unregistered name degrades to `local` with a "not registered"
// warning. So a configuration that names an unavailable protocol still renders and
// degrades safely, and there is no compile-time list of known protocol names anywhere.

import Foundation

@MainActor
public final class ChatTransportRegistry {

    public static let shared = ChatTransportRegistry()

    /// The reserved built-in protocol name. Always available, never overridable.
    public static let reservedLocalName = "local"

    /// Logger for registration-time diagnostics (build-time diagnostics flow through the
    /// logger handed to makeIfViable). Hosts may replace it; defaults to the console.
    public var logger: any ChatLogger = ConsoleChatLogger()

    private var factories: [String: ChatTransportFactory] = [:]

    private init() {
        // The scripted person-to-person / group backend, a built-in like `local` but
        // registered (not reserved) so a host can still override the name. Seeded here so
        // the component works standalone; drives the dual-alignment demos with no wire.
        factories["local-p2p"] = { config, _ in
            LocalP2PTransport(config: config)
        }
    }

    /// Registers a factory under a protocol name. Last registration wins (logged). The
    /// reserved name `local` and the empty string are rejected. Main-actor-confined,
    /// like element registration - call at launch, before any chat view is built.
    public func register(_ name: String, factory: @escaping ChatTransportFactory) {
        guard name != Self.reservedLocalName else {
            logger.log(
                "Chat: transport name 'local' is reserved (the built-in transport); ignoring registration", .warning)
            return
        }
        guard !name.isEmpty else {
            logger.log(
                "Chat: a transport name must be non-empty; ignoring registration", .warning)
            return
        }
        if factories[name] != nil {
            logger.log(
                "Chat: transport '\(name)' re-registered; the latest registration wins", .info)
        }
        factories[name] = factory
    }

    /// Whether a protocol name resolves to a transport (the reserved `local`, or a
    /// registered factory). Public so hosts and wiring tests can introspect registration.
    public func isRegistered(_ name: String) -> Bool {
        name == Self.reservedLocalName || factories[name] != nil
    }

    /// Builds the transport for a host-injected config, if it is VIABLE right now. Returns nil when a
    /// REGISTERED protocol's factory throws (e.g. openai-sse before its baseURL, acp before its
    /// command): that is a transient "config not complete yet" state, and the deferred-config chat
    /// stays inert and waits for a completer config injection rather than freezing on a fallback.
    /// `local` (built in) and an UNREGISTERED name both yield a transport - an unregistered name is a
    /// PERMANENT condition (registration happens at launch, never at runtime), so it degrades to
    /// `local` with a warning rather than blocking the chat forever.
    func makeIfViable(protocolName: String, transport: [String: Any], logger: any ChatLogger) -> (any ChatTransport)? {
        let transportConfig = ChatTransportConfig(protocolName: protocolName, settings: transport)

        if protocolName == Self.reservedLocalName {
            return LocalChatTransport(config: transportConfig, logger: logger)
        }

        guard let factory = factories[protocolName] else {
            logger.log(
                "Chat transport '\(protocolName)' is not registered (link its module and call its register()); using 'local'",
                .warning)
            return LocalChatTransport(config: transportConfig, logger: logger)
        }

        do {
            return try factory(transportConfig, logger)
        } catch {
            logger.log("Chat transport '\(protocolName)' not viable yet (\(error)); awaiting a complete config", .verbose)
            return nil
        }
    }
}
