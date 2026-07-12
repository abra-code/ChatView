// Sources/ACP/ChatViewACP.swift
//
// Registration entry point for the ACP transport module.

import Foundation
import ChatView

public enum ChatViewACP {

    /// Registers the `acp` transport with the shared chat transport registry. Call once
    /// at app launch, before creating any ChatView whose config names "acp". Idempotent
    /// (last registration for a name wins). macOS only - an ACP agent runs as a
    /// subprocess, which iOS cannot spawn; on other platforms this is a no-op and `acp`
    /// degrades to `local` like any unregistered protocol.
    @MainActor
    public static func register() {
#if os(macOS)
        ChatTransportRegistry.shared.register("acp") { config, logger in
            try ACPChatTransport(config: config, logger: logger)
        }
#endif
    }
}
