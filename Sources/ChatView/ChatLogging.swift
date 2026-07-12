// Sources/ChatView/ChatLogging.swift
//
// The component's own logging contract. Mirrors the shape (and raw levels) of ActionUI's
// ActionUILogger so an ActionUI host adapts with a two-line wrapper, but the component and
// the transport modules depend only on this.

import Foundation

/// Severity levels for component logging. Raw values match ActionUI's LoggerLevel so an
/// adapter is a raw-value passthrough. Lower value = higher severity.
public enum ChatLogLevel: Int, Sendable {
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4
    case verbose = 5
}

/// The logger handed to the chat component and its transports.
public protocol ChatLogger: Sendable {
    func log(_ message: String, _ level: ChatLogLevel)
}

/// Default logger: prints to stdout. Hosts replace it with their own conformer.
public struct ConsoleChatLogger: ChatLogger {
    public init() {}
    public func log(_ message: String, _ level: ChatLogLevel) {
        print("ChatView [\(level)]: \(message)")
    }
}
