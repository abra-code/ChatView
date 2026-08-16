// Sources/ACP/ACPRemoteConnection.swift
//
// The client half of the bridge protocol: JSON-RPC 2.0 over one WebSocket, one message per
// TEXT frame.
//
// This is the network twin of ACPConnection, and the dispatch shape is deliberately identical
// (method+id is a request, method alone is a notification, id alone is a response) minus the
// line buffering, since a frame is already a message. Ungated: unlike ACPConnection there is
// no subprocess here, so this compiles and runs on iOS, which is the entire point.
//
// Two invariants carried over from the stdio transport, both learned the hard way:
//
// I1 - a handshake watchdog must close the SOCKET, never race the request. Racing an await
//      against a timeout in a task group deadlocks; closing the transport underneath the
//      pending continuation makes it throw through the normal error path.
// I2 - close-fails-everything, exactly once. A connection object is single-use: one per
//      attempt. Reconnect logic lives OUTSIDE it, in the transport.

import Foundation
import ChatView

/// The socket the connection talks through. A protocol, not a concrete
/// URLSessionWebSocketTask, so tests can drive the whole client without a server (and so a
/// host on a platform with a better socket can supply one).
protocol ACPRemoteSocket: AnyObject, Sendable {
    func connect()
    func sendText(_ text: String)
    /// Round-trips a keepalive. A silently reaped flow (NAT timeout, a phone changing networks)
    /// never delivers a receive error, so without this the client can sit in `.connected` on a
    /// dead socket indefinitely - which on a phone is the common case, not the rare one.
    func sendPing(onPong: @escaping @Sendable ((any Error)?) -> Void)
    func close()
}

protocol ACPRemoteSocketDelegate: AnyObject, Sendable {
    func socketDidOpen()
    func socketDidReceiveText(_ text: String)
    func socketDidClose(error: (any Error)?)
}

protocol ACPRemoteSocketFactory: Sendable {
    func makeSocket(url: URL,
                    headers: [String: String],
                    delegate: any ACPRemoteSocketDelegate) -> any ACPRemoteSocket
}

/// A JSON-RPC error returned by the bridge, or a connection failure.
struct ACPRemoteError: Error, CustomStringConvertible {
    let code: Int?
    let message: String

    var description: String {
        if let code {
            return "\(message) (code \(code))"
        }
        return message
    }
}

final class ACPRemoteConnection: @unchecked Sendable, ACPRemoteSocketDelegate {

    typealias NotificationHandler = @Sendable (String, [String: Any]) -> Void
    /// A request FROM the bridge (only `session/request_permission` today). Returning nil
    /// answers with "method not found".
    typealias RequestHandler = @Sendable (String, [String: Any]) async -> [String: Any]?
    typealias OpenHandler = @Sendable () -> Void
    typealias CloseHandler = @Sendable ((any Error)?) -> Void

    private let logger: any ChatLogger
    private let onNotification: NotificationHandler
    private let onRequest: RequestHandler
    private let onOpen: OpenHandler
    private let onClose: CloseHandler

    private let lock = NSLock()
    private var socket: (any ACPRemoteSocket)?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], any Error>] = [:]
    private var closed = false
    private var keepalive: Task<Void, Never>?
    private static let pingInterval: TimeInterval = 30

    init(logger: any ChatLogger,
         onNotification: @escaping NotificationHandler,
         onRequest: @escaping RequestHandler,
         onOpen: @escaping OpenHandler,
         onClose: @escaping CloseHandler) {
        self.logger = logger
        self.onNotification = onNotification
        self.onRequest = onRequest
        self.onOpen = onOpen
        self.onClose = onClose
    }

    /// Hands the connection its socket and starts it. Separate from `init` only because the
    /// socket factory needs the connection as its delegate.
    func attach(socket: any ACPRemoteSocket) {
        let refused: Bool = lock.withLock {
            if closed {
                return true
            }
            self.socket = socket
            return false
        }
        if refused {
            // Closed before we were even wired up: do not leave a live socket behind.
            socket.close()
            return
        }
        socket.connect()
        startKeepalive()
    }

    private func startKeepalive() {
        let task = Task { [weak self] in
            while let self, !self.isClosed {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                if Task.isCancelled || self.isClosed {
                    return
                }
                let socket: (any ACPRemoteSocket)? = self.lock.withLock { self.closed ? nil : self.socket }
                socket?.sendPing { [weak self] error in
                    guard let self, let error else {
                        return
                    }
                    self.logger.log("acp-remote: keepalive failed; treating the socket as dead", .warning)
                    self.close(error: error)
                }
            }
        }
        lock.withLock { keepalive = task }
    }

    // MARK: - ACPRemoteSocketDelegate

    func socketDidOpen() {
        onOpen()
    }

    func socketDidReceiveText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // A frame we cannot parse is dropped, not fatal: forward compatibility beats
            // tearing down a working session over one bad message.
            logger.log("acp-remote: dropping an unparseable frame", .warning)
            return
        }

        if let method = message["method"] as? String {
            if let requestID = message["id"] {
                handleInboundRequest(method: method, id: requestID,
                                     params: (message["params"] as? [String: Any]) ?? [:])
            } else {
                onNotification(method, (message["params"] as? [String: Any]) ?? [:])
            }
            return
        }

        guard let responseID = message["id"] as? Int else {
            return
        }
        let continuation: CheckedContinuation<[String: Any], any Error>? = lock.withLock {
            pending.removeValue(forKey: responseID)
        }
        guard let continuation else {
            logger.log("acp-remote: response for an unknown request id \(responseID)", .warning)
            return
        }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: ACPRemoteError(code: error["code"] as? Int,
                                                         message: (error["message"] as? String) ?? "bridge error"))
        } else {
            continuation.resume(returning: (message["result"] as? [String: Any]) ?? [:])
        }
    }

    func socketDidClose(error: (any Error)?) {
        close(error: error ?? ACPRemoteError(code: nil, message: "the connection to the agent bridge closed"))
    }

    private func handleInboundRequest(method: String, id: Any, params: [String: Any]) {
        let boxedID = ACPRemoteBox(id)
        let boxedParams = ACPRemoteBox(params)
        Task { [weak self] in
            guard let self else {
                return
            }
            if let result = await self.onRequest(method, boxedParams.value) {
                self.send(["jsonrpc": "2.0", "id": boxedID.value, "result": result])
            } else {
                self.send(["jsonrpc": "2.0", "id": boxedID.value,
                           "error": ["code": -32601, "message": "method not found"]])
            }
        }
    }

    // MARK: - Outbound

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let requestID: Int = try lock.withLock {
            if closed {
                throw ACPRemoteError(code: nil, message: "not connected to the agent bridge")
            }
            let next = nextRequestID
            nextRequestID += 1
            return next
        }
        // The continuation deliberately ignores task cancellation: closing the socket is what
        // resolves it (I1/I2). A cancellation-aware wait here would let a caller walk away
        // while the bridge still owes an answer, and the pending map would leak.
        return try await withCheckedThrowingContinuation { continuation in
            let refused: Bool = lock.withLock {
                if closed {
                    return true
                }
                pending[requestID] = continuation
                return false
            }
            if refused {
                continuation.resume(throwing: ACPRemoteError(code: nil, message: "not connected to the agent bridge"))
                return
            }
            send(["jsonrpc": "2.0", "id": requestID, "method": method, "params": params])
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            logger.log("acp-remote: refusing to send an unserializable message", .error)
            return
        }
        let socket: (any ACPRemoteSocket)? = lock.withLock { closed ? nil : self.socket }
        socket?.sendText(text)
    }

    /// Closes once and fails every pending request (I2). Idempotent: the socket's own close
    /// callback and an explicit close race constantly, and only one of them may notify.
    func close(error: (any Error)? = nil) {
        let teardown: (ran: Bool, socket: (any ACPRemoteSocket)?, ping: Task<Void, Never>?,
                       waiters: [CheckedContinuation<[String: Any], any Error>]) = lock.withLock {
            if closed {
                return (false, nil, nil, [])
            }
            closed = true
            let existing = socket
            socket = nil
            let ping = keepalive
            keepalive = nil
            let all = Array(pending.values)
            pending.removeAll()
            return (true, existing, ping, all)
        }
        guard teardown.ran else {
            return
        }
        teardown.ping?.cancel()
        let failure = error ?? ACPRemoteError(code: nil, message: "the connection to the agent bridge closed")
        for waiter in teardown.waiters {
            waiter.resume(throwing: failure)
        }
        teardown.socket?.close()
        onClose(error)
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }
}

/// Carries parsed JSON across a concurrency boundary. Same reasoning as the bridge's
/// BridgeJSON: these values come straight out of JSONSerialization, are never mutated after
/// boxing, and have exactly one consumer.
struct ACPRemoteBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

// MARK: - The default socket

/// `URLSessionWebSocketTask` behind the seam. Cross-platform: this is what runs on iOS.
final class URLSessionSocketFactory: ACPRemoteSocketFactory {

    init() {}

    func makeSocket(url: URL,
                    headers: [String: String],
                    delegate: any ACPRemoteSocketDelegate) -> any ACPRemoteSocket {
        URLSessionSocket(url: url, headers: headers, delegate: delegate)
    }
}

/// Refuses to follow a redirect on the upgrade.
///
/// A 3xx that moves the endpoint would carry the client to a host the transport's scheme policy
/// never approved - and the bridge token travels in the `initialize` params, which no
/// header-stripping rule protects, so a redirected socket hands a code-execution credential to
/// wherever the redirect points, in cleartext if it says `ws://`. A WebSocket upgrade has no
/// legitimate reason to be redirected; the config names the bridge.
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class URLSessionSocket: NSObject, ACPRemoteSocket, @unchecked Sendable {

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let delegate: any ACPRemoteSocketDelegate
    private let lock = NSLock()
    private var opened = false
    private var finished = false

    init(url: URL, headers: [String: String], delegate: any ACPRemoteSocketDelegate) {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // A private session rather than URLSession.shared, purely so the redirect policy above can
        // be installed: a shared session takes no delegate. Invalidated in finish(), which is what
        // releases the delegate the session retains.
        self.session = URLSession(configuration: .default,
                                  delegate: NoRedirectSessionDelegate(),
                                  delegateQueue: nil)
        self.task = session.webSocketTask(with: request)
        self.delegate = delegate
        super.init()
    }

    func connect() {
        task.resume()
        // URLSessionWebSocketTask has no "did open" callback without a session delegate, and a
        // session delegate would need its own queue and lifetime. The first successful receive
        // (or send) means the upgrade completed, so treat the first receive arming as open -
        // the handshake watchdog upstream is what actually decides whether it worked.
        noteOpen()
        receiveNext()
    }

    private func noteOpen() {
        let first: Bool = lock.withLock {
            if opened {
                return false
            }
            opened = true
            return true
        }
        if first {
            delegate.socketDidOpen()
        }
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .failure(let error):
                self.finish(error: error)
            case .success(let message):
                switch message {
                case .string(let text):
                    self.delegate.socketDidReceiveText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.delegate.socketDidReceiveText(text)
                    }
                @unknown default:
                    break
                }
                self.receiveNext()
            }
        }
    }

    func sendText(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.finish(error: error)
            }
        }
    }

    func sendPing(onPong: @escaping @Sendable ((any Error)?) -> Void) {
        task.sendPing { error in
            onPong(error)
        }
    }

    func close() {
        finish(error: nil)
    }

    private func finish(error: (any Error)?) {
        let first: Bool = lock.withLock {
            if finished {
                return false
            }
            finished = true
            return true
        }
        guard first else {
            return
        }
        task.cancel(with: .goingAway, reason: nil)
        // Releases the session's strong reference to its delegate. A connection object is
        // single-use, so its session is too.
        session.finishTasksAndInvalidate()
        delegate.socketDidClose(error: error)
    }
}
