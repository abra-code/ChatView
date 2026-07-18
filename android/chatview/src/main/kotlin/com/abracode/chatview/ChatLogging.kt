package com.abracode.chatview

// Port of Sources/ChatView/ChatLogging.swift.
//
// The component's own logging contract. Mirrors the shape (and raw levels) of ActionUI's ActionUILogger so an
// ActionUI host adapts with a two-line wrapper, but the component and the transport modules depend only on this.

/**
 * Severity levels for component logging. Raw values match ActionUI's LoggerLevel so an adapter is a raw-value
 * passthrough. Lower value = higher severity.
 */
enum class ChatLogLevel(val rawValue: Int) {
    ERROR(1),
    WARNING(2),
    INFO(3),
    DEBUG(4),
    VERBOSE(5),
}

/** The logger handed to the chat component and its transports. */
interface ChatLogger {
    fun log(message: String, level: ChatLogLevel)
}

/** Default logger: prints to stdout. Hosts replace it with their own conformer. */
class ConsoleChatLogger : ChatLogger {
    override fun log(message: String, level: ChatLogLevel) {
        println("ChatView [$level]: $message")
    }
}
