// Sources/ACP/ChatViewACP.swift
//
// Registration entry point for the ACP transport module.

import Foundation
import ChatView

public enum ChatViewACP {

    /// Registers this module's transports with the shared chat transport registry. Call once
    /// at app launch, before creating any ChatView whose config names either of them.
    /// Idempotent (last registration for a name wins).
    ///
    /// Two transports, and the difference is where the agent runs:
    ///
    /// - `acp` spawns an Agent Client Protocol agent as a local SUBPROCESS over stdio. macOS
    ///   only, because no other Apple platform can spawn one; elsewhere it is simply not
    ///   registered and degrades to `local` like any unknown protocol.
    /// - `acp-remote` connects to a `chatview-acp-bridge` over a WebSocket, where the agent
    ///   runs on some other machine. Every platform, including iOS - it owns no process, only
    ///   a socket. This is how a phone drives an agent running on a Mac.
    @MainActor
    public static func register() {
#if os(macOS)
        ChatTransportRegistry.shared.register("acp") { config, logger in
            try ACPChatTransport(config: config, logger: logger)
        }
#endif
        // Deliberately OUTSIDE the platform gate: this is the one that has to reach iOS.
        ChatTransportRegistry.shared.register("acp-remote") { config, logger in
            try ACPRemoteTransport(config: config, logger: logger)
        }
    }
}
