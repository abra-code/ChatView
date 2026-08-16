package com.abracode.chatview.acp

// Port of Sources/ACP/ChatViewACP.swift's registration entry point, minus the macOS-only `acp` half: Android cannot
// spawn an agent subprocess, so `acp-remote` (a network transport, every platform) is the only protocol this module
// registers.

import com.abracode.chatview.ChatTransportRegistry

/**
 * Registers the `acp-remote` transport. Call once at launch, before any chat view is built:
 *
 * ```kotlin
 * ChatViewAcpRemote.register()
 * ```
 *
 * A host then selects it through the injected config channel:
 * `{ "protocol": "acp-remote", "transport": { "url": "wss://mac:8737/acp", "token": "...", "session": "latest" } }`.
 *
 * The token is remote code execution on the bridge host, so it is HOST-INJECTED at runtime and never stored by the
 * component; put it in an Android Keystore-backed EncryptedSharedPreferences, not in a document.
 */
object ChatViewAcpRemote {
    fun register() {
        ChatTransportRegistry.shared.register("acp-remote") { config, logger ->
            AcpRemoteTransport(config, logger)
        }
    }
}
