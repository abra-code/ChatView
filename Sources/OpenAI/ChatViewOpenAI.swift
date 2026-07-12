// Sources/OpenAI/ChatViewOpenAI.swift
//
// Registration entry point for the OpenAI SSE transport module.

import Foundation
import ChatView

public enum ChatViewOpenAI {

    /// Registers the `openai-sse` transport with the shared chat transport registry.
    /// Call once at app launch, before creating any ChatView whose config names
    /// "openai-sse". Idempotent (last registration for a name wins).
    @MainActor
    public static func register() {
        ChatTransportRegistry.shared.register("openai-sse") { config, logger in
            try OpenAIChatTransport(config: config, logger: logger)
        }
    }
}
