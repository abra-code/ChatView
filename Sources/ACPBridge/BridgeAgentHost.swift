// Sources/ACPBridge/BridgeAgentHost.swift
//
// Owns the one stdio ACP agent the bridge re-hosts: spawning it, running `initialize` once
// and caching the result, relaying requests to it, and reporting its death.
//
// The agent is completely unmodified and completely unaware of any of this. It thinks it is
// talking to a single local editor over stdin/stdout, which is exactly the point - every
// existing ACP agent works over the bridge with no cooperation from its authors.

#if os(macOS)

import Foundation
import ChatView
import ChatViewACP

package final class BridgeAgentHost: @unchecked Sendable {

    package typealias NotificationHandler = @Sendable (String, [String: Any]) -> Void
    package typealias RequestHandler = @Sendable (String, [String: Any]) async -> [String: Any]?
    /// (exit status, stderr tail) - the tail is what makes a spawn failure diagnosable from a
    /// phone that can see nothing of the host.
    package typealias ExitHandler = @Sendable (Int32?, String) -> Void

    private let config: BridgeAgentConfig
    private let logger: any ChatLogger
    private let onNotification: NotificationHandler
    private let onRequest: RequestHandler
    private let onExit: ExitHandler

    private let lock = NSLock()
    private var connection: ACPConnection?
    private var cachedInitialize: [String: Any]?
    /// Concurrent callers of `ensureRunning` await the SAME spawn rather than racing to start
    /// two agents. Cleared when the agent exits so the next session/new respawns.
    private var spawning: Task<JSONPayload, any Error>?
    private var stopped = false

    package init(config: BridgeAgentConfig,
                 logger: any ChatLogger,
                 onNotification: @escaping NotificationHandler,
                 onRequest: @escaping RequestHandler,
                 onExit: @escaping ExitHandler) {
        self.config = config
        self.logger = logger
        self.onNotification = onNotification
        self.onRequest = onRequest
        self.onExit = onExit
    }

    package var initializeResult: [String: Any]? {
        lock.withLock { cachedInitialize }
    }

    package var isRunning: Bool {
        lock.withLock { connection != nil }
    }

    /// Spawns the agent if it is not already up and returns its `initialize` result.
    package func ensureRunning() async throws -> [String: Any] {
        let task: Task<JSONPayload, any Error> = try lock.withLock {
            if stopped {
                throw ACPConnectionError(code: -32003, message: "the bridge is shutting down")
            }
            if let cachedInitialize, connection != nil {
                let cached = JSONPayload(cachedInitialize)
                return Task { cached }
            }
            if let spawning {
                return spawning
            }
            let task = Task { JSONPayload(try await self.spawn()) }
            spawning = task
            return task
        }
        do {
            return try await task.value.value
        } catch {
            lock.withLock { spawning = nil }
            throw error
        }
    }

    private func spawn() async throws -> [String: Any] {
        let connection = ACPConnection(
            logger: logger,
            onNotification: { [weak self] method, params in
                self?.onNotification(method, params)
            },
            onRequest: { [weak self] method, params in
                guard let self else {
                    return nil
                }
                return await self.onRequest(method, params)
            },
            onClose: { [weak self] status in
                self?.handleExit(status: status)
            })

        do {
            try connection.launch(command: config.command,
                                  cwd: config.cwd,
                                  environment: config.env)
        } catch {
            connection.drainStderr()
            let tail = connection.stderrTailText()
            let detail = tail.isEmpty ? "\(error)" : "\(error)\n\(tail)"
            throw ACPConnectionError(code: -32003, message: "could not start the agent: \(detail)")
        }

        lock.withLock { self.connection = connection }

        do {
            let result = try await connection.request("initialize", [
                "protocolVersion": 1,
                // The bridge advertises NO fs and NO terminal capabilities, exactly like the
                // stdio transport. Proxying host filesystem access to a phone is a different
                // feature with a much larger threat model.
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
                "clientInfo": ["name": "chatview-acp-bridge", "title": "ChatView ACP Bridge", "version": "0.1.0"],
            ])
            lock.withLock { cachedInitialize = result }
            return result
        } catch {
            connection.drainStderr()
            let tail = connection.stderrTailText()
            connection.stop()
            lock.withLock { self.connection = nil }
            let detail = tail.isEmpty ? "\(error)" : "\(error)\n\(tail)"
            throw ACPConnectionError(code: -32003, message: "the agent failed to initialize: \(detail)")
        }
    }

    private func handleExit(status: Int32?) {
        let previous: ACPConnection? = lock.withLock {
            let existing = connection
            connection = nil
            cachedInitialize = nil
            spawning = nil
            return existing
        }
        guard previous != nil else {
            return
        }
        previous?.drainStderr()
        let tail = previous?.stderrTailText() ?? ""
        onExit(status, tail)
    }

    package func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let connection = lock.withLock({ self.connection }) else {
            throw ACPConnectionError(code: -32003, message: "the agent is not running")
        }
        return try await connection.request(method, params)
    }

    package func notify(_ method: String, _ params: [String: Any]) {
        lock.withLock { self.connection }?.notify(method, params)
    }

    package func stop() {
        let existing: ACPConnection? = lock.withLock {
            stopped = true
            let connection = self.connection
            self.connection = nil
            cachedInitialize = nil
            spawning = nil
            return connection
        }
        existing?.stop()
    }
}

#endif
