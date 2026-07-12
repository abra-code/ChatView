// Tests/OpenAITests/StubURLProtocol.swift
//
// A URLProtocol stub that serves canned responses (streamed SSE chunks, a /models list, a
// non-200 error body) keyed by URL path, so the OpenAI transport's end-to-end path can be
// driven without a real server. A test configures a URLSession with this protocol class and
// injects it into OpenAIChatTransport.
//
// Delivery is synchronous in startLoading: the chunks are pushed then the stream terminates
// per `terminal` (finish / fail mid-stream / hang). `hang` delivers the chunks and never
// finishes, so a test can drive cancellation while a turn is streaming.

import Foundation

final class StubURLProtocol: URLProtocol {

    enum Terminal {
        case finish            // urlProtocolDidFinishLoading after the chunks
        case failMidStream     // didFailWithError after the chunks (a mid-stream disconnect)
        case hang              // deliver the chunks, then never finish (the test cancels)
    }

    struct Stub {
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var chunks: [Data] = []
        var terminal: Terminal = .finish
    }

    // Lock-guarded per-path registry (@unchecked Sendable via the lock).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]

    static func setStub(_ stub: Stub, forPath path: String) {
        lock.withLock { stubs[path] = stub }
    }

    static func reset() {
        lock.withLock { stubs.removeAll() }
    }

    private static func stub(forPath path: String) -> Stub? {
        lock.withLock { stubs[path] }
    }

    /// Convenience: an SSE data event ("data: <json>\n\n").
    static func sseEvent(_ json: String) -> String {
        "data: \(json)\n\n"
    }

    static let doneEvent = "data: [DONE]\n\n"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let stub = Self.stub(forPath: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        switch stub.terminal {
        case .finish:
            client?.urlProtocolDidFinishLoading(self)
        case .failMidStream:
            // startLoading runs off the main thread; pause so the delivered bytes reach the
            // consumer before the failure (a synchronous failure makes URLSession drop the
            // buffered bytes, which is not what a real mid-stream disconnect looks like).
            Thread.sleep(forTimeInterval: 0.25)
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .hang:
            break
        }
    }
}
