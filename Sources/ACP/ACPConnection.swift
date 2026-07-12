// Sources/ACP/ACPConnection.swift
//
// The wire layer of the ACP transport: a newline-delimited JSON-RPC 2.0 connection to
// an agent subprocess over stdio. The client launches the agent (ACP's stdio model),
// writes one JSON-RPC message per line to the agent's stdin, and reads one message per
// line from its stdout. This file knows JSON-RPC framing and correlation only; the ACP
// method vocabulary lives in ACPChatTransport. macOS-only: spawning a subprocess
// (Foundation.Process) does not exist on iOS - the ACP remote transport (HTTP/WS) is
// still a work in progress upstream, so the framing here is kept in its own layer so a
// remote framing can swap in later.
//
// `@unchecked Sendable`: mutable state (the pending-request map, the id counter, the
// process handle, the line buffers, the termination flag) is guarded by `lock`; pipes
// and closures are immutable. Lines are handled in arrival order on the pipes' GCD
// readability callbacks; agent->client requests are answered from a per-request Task
// so a slow handler (a permission prompt waiting on the user) does not stall the
// stream.

#if os(macOS)

import Foundation
import ChatView

/// An error the agent returned for a JSON-RPC request, or a connection failure.
struct ACPConnectionError: Error, CustomStringConvertible {
    let code: Int?
    let message: String

    var description: String {
        if let code {
            return "\(message) (code \(code))"
        }
        return message
    }
}

final class ACPConnection: @unchecked Sendable {

    /// A notification from the agent (method, params).
    typealias NotificationHandler = @Sendable (String, [String: Any]) -> Void
    /// A request from the agent (method, params) -> result. Return nil to answer with
    /// a JSON-RPC "method not found" error (the capability was not advertised).
    typealias RequestHandler = @Sendable (String, [String: Any]) async -> [String: Any]?
    /// The agent process ended (exit status, nil when only the stream closed).
    typealias CloseHandler = @Sendable (Int32?) -> Void

    private let logger: any ChatLogger
    private let onNotification: NotificationHandler
    private let onRequest: RequestHandler
    private let onClose: CloseHandler

    private let inPipe = Pipe()     // client -> agent stdin
    private let outPipe = Pipe()    // agent stdout -> client
    private let errPipe = Pipe()    // agent stderr -> log

    private let lock = NSLock()
    private var process: Process?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], any Error>] = [:]
    private var closed = false
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    init(logger: any ChatLogger,
         onNotification: @escaping NotificationHandler,
         onRequest: @escaping RequestHandler,
         onClose: @escaping CloseHandler) {
        self.logger = logger
        self.onNotification = onNotification
        self.onRequest = onRequest
        self.onClose = onClose
    }

    /// Spawns the agent. `command` is the argv (resolved through /usr/bin/env, so a bare
    /// name found on PATH and an absolute path both work); `cwd` roots the process.
    func launch(command: [String], cwd: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        }
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.terminationHandler = { [weak self] finished in
            self?.handleClose(exitStatus: finished.terminationStatus)
        }
        try process.run()
        lock.withLock { self.process = process }
        startReading()
    }

    /// Starts draining stdout (one JSON-RPC message per line) and stderr (to the log).
    /// Deliberately uses `readabilityHandler` (GCD-driven) with manual line buffering,
    /// NOT `FileHandle.bytes.lines`: the AsyncBytes iterator performs a BLOCKING read()
    /// on a Swift-concurrency cooperative thread, and two such readers (stdout + stderr)
    /// can starve the fixed-width cooperative pool and deadlock the whole process.
    func startReading() {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let data = handle.availableData
            if data.isEmpty {   // EOF: the agent's stdout closed
                handle.readabilityHandler = nil
                self.handleClose(exitStatus: nil)
                return
            }
            let lines = self.lock.withLock { Self.splitLines(buffer: &self.stdoutBuffer, appending: data) }
            for line in lines {
                self.handleLine(line)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let data = handle.availableData
            if data.isEmpty {   // stderr closing with the process is unremarkable
                handle.readabilityHandler = nil
                return
            }
            let lines = self.lock.withLock { Self.splitLines(buffer: &self.stderrBuffer, appending: data) }
            for line in lines {
                self.logger.log("ACP agent stderr: \(line)", .verbose)
            }
        }
    }

    /// Appends `data` to `buffer` and peels off every complete (newline-terminated) line.
    /// Call under `lock`; the trailing partial line stays buffered.
    private static func splitLines(buffer: inout Data, appending data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    /// Sends a request and suspends until the agent responds. Throws the agent's
    /// JSON-RPC error, or a connection error if the agent is gone.
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in
            let id = nextRequestID
            nextRequestID += 1
            return id
        }
        return try await withCheckedThrowingContinuation { continuation in
            let refused = lock.withLock { () -> Bool in
                if closed {
                    return true
                }
                pending[id] = continuation
                return false
            }
            if refused {
                continuation.resume(throwing: ACPConnectionError(code: nil, message: "agent connection is closed"))
                return
            }
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    /// Sends a notification (no response expected).
    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Terminates the agent process (if running) and fails anything in flight.
    func stop() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let process = lock.withLock { self.process }
        process?.terminationHandler = nil
        process?.terminate()
        handleClose(exitStatus: nil, notify: false)
    }

    // MARK: - Inbound

    /// Dispatches one inbound line: a response resumes its pending request; a method
    /// with an id is an agent->client request (answered via `onRequest` on its own
    /// task); a method without an id is a notification. Internal for tests.
    func handleLine(_ line: String) {
        guard !line.isEmpty else {
            return
        }
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            logger.log("ACP: dropping non-JSON line from agent: \(line.prefix(200))", .warning)
            return
        }

        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] {
                Task { [weak self] in
                    if let result = await self?.onRequest(method, params) {
                        self?.send(["jsonrpc": "2.0", "id": id, "result": result])
                    } else {
                        self?.send(["jsonrpc": "2.0", "id": id,
                                    "error": ["code": -32601, "message": "Method not supported by this client: \(method)"]])
                    }
                }
            } else {
                onNotification(method, params)
            }
            return
        }

        // A response: correlate by id.
        guard let id = (message["id"] as? NSNumber)?.intValue,
              let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else {
            logger.log("ACP: response with no matching request; dropping", .verbose)
            return
        }
        if let error = message["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue
            let text = (error["message"] as? String) ?? "agent error"
            continuation.resume(throwing: ACPConnectionError(code: code, message: text))
        } else {
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    // MARK: - Outbound

    /// Serializes one JSON-RPC message onto the agent's stdin as a single line.
    /// Writes are serialized by `lock` so concurrent tasks cannot interleave lines.
    /// `.withoutEscapingSlashes`: method names like "session/new" go out literally
    /// (JSONSerialization would otherwise emit "session\\/new" - valid JSON, but
    /// needlessly unlike what every other ACP implementation puts on the wire).
    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            logger.log("ACP: failed to encode outbound message", .warning)
            return
        }
        data.append(0x0A)   // newline framing
        lock.withLock {
            guard !closed else {
                return
            }
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                logger.log("ACP: writing to agent failed: \(error)", .warning)
            }
        }
    }

    // MARK: - Teardown

    /// Marks the connection closed (once), fails all pending requests, and reports the
    /// closure so the transport can surface "agent exited" to the transcript.
    private func handleClose(exitStatus: Int32?, notify: Bool = true) {
        let (continuations, first) = lock.withLock { () -> ([CheckedContinuation<[String: Any], any Error>], Bool) in
            if closed {
                return ([], false)
            }
            closed = true
            let waiting = Array(pending.values)
            pending.removeAll()
            return (waiting, true)
        }
        guard first else {
            return
        }
        for continuation in continuations {
            continuation.resume(throwing: ACPConnectionError(code: nil, message: "agent connection closed"))
        }
        if notify {
            onClose(exitStatus)
        }
    }
}

#endif
