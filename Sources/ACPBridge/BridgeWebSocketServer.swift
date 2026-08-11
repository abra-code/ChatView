// Sources/ACPBridge/BridgeWebSocketServer.swift
//
// The network half of the bridge: an NWListener speaking WebSocket, and one
// BridgeClientConnection per attached client carrying JSON-RPC 2.0, one message per TEXT
// frame.
//
// The framing deliberately mirrors ACPConnection.handleLine - method+id is a request,
// method alone is a notification, id alone is a response - because the bridge is a
// JSON-RPC proxy in both directions and two different dispatch shapes in one process would
// be a standing source of bugs. The difference is only what carries the bytes: newline
// framing over a pipe there, TEXT frames here.

#if os(macOS)

import Foundation
import Network
import ChatView
import ChatViewACP

/// One connected client. Owns its socket, its outbound request ids, and the continuations
/// waiting on their answers.
package final class BridgeClientConnection: @unchecked Sendable {

    package let id = UUID()

    private let connection: NWConnection
    private let logger: any ChatLogger
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], any Error>] = [:]
    private var closed = false

    /// Set by the server once the connection is accepted. Inbound messages are handed over
    /// verbatim; this class does no protocol interpretation of its own.
    package var onMessage: (@Sendable (BridgeClientConnection, [String: Any]) -> Void)?
    package var onClose: (@Sendable (BridgeClientConnection) -> Void)?
    /// The server's own cleanup, kept separate from `onClose` so a consumer assigning that
    /// property cannot unregister the connection from the server's table.
    var onCloseInternal: (@Sendable (BridgeClientConnection) -> Void)?

    init(connection: NWConnection, logger: any ChatLogger, queue: DispatchQueue) {
        self.connection = connection
        self.logger = logger
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .failed(let error):
                self.logger.log("acp-bridge: client \(self.id) failed: \(error)", .warning)
                self.close()
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else {
                return
            }
            if let error {
                self.logger.log("acp-bridge: client \(self.id) receive error: \(error)", .warning)
                self.close()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                self.close()
                return
            }
            // Binary frames are ignored rather than treated as an error: the spec says TEXT
            // only, and a client library that sends a stray ping payload should not lose its
            // session over it.
            if metadata?.opcode == .text, let content, !content.isEmpty {
                self.dispatch(content)
            }
            self.receiveNext()
        }
    }

    private func dispatch(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            sendError(id: nil, code: -32700, message: "parse error")
            return
        }
        // No batching: a JSON array is a well-formed request the bridge chooses not to serve.
        guard let message = object as? [String: Any] else {
            sendError(id: nil, code: -32600, message: "batched requests are not supported")
            return
        }

        // A response to something the bridge asked (session/request_permission). Resume the
        // waiter under the lock and outside it call nothing - a continuation resumed while
        // holding a lock can re-enter this class on the same thread.
        if message["method"] == nil, let responseID = message["id"] as? Int {
            let continuation: CheckedContinuation<[String: Any], any Error>? = lock.withLock {
                pending.removeValue(forKey: responseID)
            }
            guard let continuation else {
                logger.log("acp-bridge: client \(id) answered unknown request id \(responseID)", .warning)
                return
            }
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: ACPConnectionError(code: error["code"] as? Int,
                                                                 message: (error["message"] as? String) ?? "client error"))
            } else {
                continuation.resume(returning: (message["result"] as? [String: Any]) ?? [:])
            }
            return
        }

        onMessage?(self, message)
    }

    // MARK: - Outbound

    package func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            logger.log("acp-bridge: refusing to send an unserializable message to client \(id)", .error)
            return
        }
        sendRaw(data)
    }

    /// Sends bytes that are already a serialized JSON-RPC message. Replay uses this so a
    /// replayed notification is byte-identical to the one a live client received.
    package func sendRaw(_ data: Data) {
        if lock.withLock({ closed }) {
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            if let error, let self {
                self.logger.log("acp-bridge: send to client \(self.id) failed: \(error)", .warning)
                self.close()
            }
        })
    }

    /// Takes the boxed id rather than a bare `Any?` on purpose. The unboxed form is what a
    /// caller reaches for by reflex after the id has been through a JSONRPCID, and passing the
    /// BOX by mistake produces an unserializable envelope that fails at runtime instead of at
    /// compile time. Making the box the only accepted type removes the trap.
    package func sendResult(id messageID: JSONRPCID, result: [String: Any]) {
        guard let value = messageID.value else {
            return
        }
        send(["jsonrpc": "2.0", "id": value, "result": result])
    }

    package func sendError(id messageID: JSONRPCID, code: Int, message: String) {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        envelope["id"] = messageID.value ?? NSNull()
        send(envelope)
    }

    package func sendError(id messageID: Any?, code: Int, message: String) {
        sendError(id: JSONRPCID(messageID), code: code, message: message)
    }

    /// Asks the client something and waits for its answer (only `session/request_permission`
    /// today). Throws if the socket closes first, so a caller never parks forever on a phone
    /// that went away.
    package func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let requestID: Int = try lock.withLock {
            if closed {
                throw ACPConnectionError(code: nil, message: "client disconnected")
            }
            let next = nextRequestID
            nextRequestID += 1
            return next
        }
        return try await withCheckedThrowingContinuation { continuation in
            let refused: Bool = lock.withLock {
                if closed {
                    return true
                }
                pending[requestID] = continuation
                return false
            }
            if refused {
                continuation.resume(throwing: ACPConnectionError(code: nil, message: "client disconnected"))
                return
            }
            send(["jsonrpc": "2.0", "id": requestID, "method": method, "params": params])
        }
    }

    package func close() {
        // The `closed` latch is the ONLY thing deciding who runs the teardown. An earlier
        // version also consulted `waiters` and `connection.state`, which let two concurrent
        // closers both pass (each seeing no waiters and a not-yet-cancelled connection) and
        // fire `onClose` twice - besides reading NWConnection.state off its own queue.
        let teardown: (ran: Bool, waiters: [CheckedContinuation<[String: Any], any Error>]) = lock.withLock {
            if closed {
                return (false, [])
            }
            closed = true
            let all = Array(pending.values)
            pending.removeAll()
            return (true, all)
        }
        guard teardown.ran else {
            return
        }
        for waiter in teardown.waiters {
            waiter.resume(throwing: ACPConnectionError(code: nil, message: "client disconnected"))
        }
        connection.cancel()
        // Both hooks fire. `onCloseInternal` belongs to the server (it drops the connection
        // from its table); `onClose` belongs to whoever accepted it. Collapsing them into one
        // settable property means the consumer's assignment silently replaces the server's
        // bookkeeping, and every connection then leaks for the bridge's lifetime.
        onCloseInternal?(self)
        onClose?(self)
    }

    package func closeAfterAuthFailure() {
        // 4401 is the bridge's "your token is wrong" close code; a client uses it to stop
        // retrying with the same credentials instead of hammering the listener.
        sendError(id: nil, code: -32000, message: "authentication failed")
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.close()
        }
    }
}

/// Carries a listener start failure back out of the state handler, which runs on the network
/// queue while `start` is blocked on a semaphore.
private final class StartFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: (any Error)?

    func set(_ error: any Error) {
        lock.withLock { self.error = error }
    }

    func take() -> (any Error)? {
        lock.withLock { error }
    }
}

/// Accepts client connections and hands each one to `onConnection`.
package final class BridgeWebSocketServer: @unchecked Sendable {

    private let logger: any ChatLogger
    private let queue = DispatchQueue(label: "com.abracode.chatview.acp-bridge.net")
    private var listener: NWListener?
    private let lock = NSLock()
    private var connections: [UUID: BridgeClientConnection] = [:]

    package var onConnection: (@Sendable (BridgeClientConnection) -> Void)?

    package init(logger: any ChatLogger) {
        self.logger = logger
    }

    /// Starts listening and returns the bound port. Pass 0 to let the OS choose one, which is
    /// what the tests do so they never collide with a developer's running bridge.
    package func start(host: String, port: UInt16) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // BIND to the configured host, do not merely prefer it. `acceptLocalOnly` means "local
        // LINK" (the LAN), not loopback, and handing NWListener only a port binds every
        // interface - so a config that said 127.0.0.1 was in fact reachable from the whole
        // network. This token is tool execution on this machine; that default has to be right.
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host),
                                                     port: NWEndpoint.Port(rawValue: port) ?? .any)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 16 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                return
            }
            let client = BridgeClientConnection(connection: connection, logger: self.logger, queue: self.queue)
            client.onCloseInternal = { [weak self] closing in
                self?.lock.withLock { _ = self?.connections.removeValue(forKey: closing.id) }
            }
            self.lock.withLock { self.connections[client.id] = client }
            self.onConnection?(client)
            client.start()
        }

        let ready = DispatchSemaphore(value: 0)
        let startFailure = StartFailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startFailure.set(error)
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        if ready.wait(timeout: .now() + 10) == .timedOut {
            listener.cancel()
            throw ACPConnectionError(code: nil, message: "the bridge listener did not become ready within 10 seconds")
        }
        if let error = startFailure.take() {
            listener.cancel()
            throw error
        }
        guard let bound = listener.port?.rawValue else {
            listener.cancel()
            throw ACPConnectionError(code: nil, message: "the bridge listener reported no port")
        }
        return bound
    }

    /// Test seam: how many connections the server still holds. A number that never falls
    /// after clients disconnect is the connection leak this exists to pin.
    package var connectionCount: Int {
        lock.withLock { connections.count }
    }

    package func stop() {
        let all: [BridgeClientConnection] = lock.withLock {
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        for client in all {
            client.close()
        }
        listener?.cancel()
        listener = nil
    }
}

#endif
