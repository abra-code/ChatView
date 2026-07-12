// Tests/OpenAITests/OpenAILiveTests.swift
//
// An optional live integration test that drives the REAL OpenAIChatTransport (its default
// URLSession, over the real network) against a running OpenAI-compatible server. Skipped
// unless OPENAI_LIVE_BASEURL is set, so the normal suite never depends on a server. This is
// the plan's "live validation" step made repeatable in one command:
//
//   # llama-server (AIChat.app) or any OpenAI-compatible endpoint:
//   OPENAI_LIVE_BASEURL=http://127.0.0.1:8080/v1 swift test --filter OpenAILiveTests
//
//   # mlx_lm.server:
//   mlx_lm.server --model <a-downloaded-model> --port 8080
//   OPENAI_LIVE_BASEURL=http://127.0.0.1:8080/v1 swift test --filter OpenAILiveTests
//
// Optional env: OPENAI_LIVE_MODEL (default "auto"), OPENAI_LIVE_APIKEY (default "").

import XCTest
@testable import ChatViewOpenAI
import ChatView

private final class LiveLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

final class OpenAILiveTests: XCTestCase {

    func testLiveStreamingTranscript() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let baseURL = env["OPENAI_LIVE_BASEURL"], !baseURL.isEmpty else {
            throw XCTSkip("set OPENAI_LIVE_BASEURL to run the live openai-sse integration test")
        }
        var settings: [String: Any] = [
            "baseURL": baseURL,
            "model": env["OPENAI_LIVE_MODEL"] ?? "auto",
            "params": ["temperature": 0.2, "max_tokens": 256],
        ]
        if let apiKey = env["OPENAI_LIVE_APIKEY"], !apiKey.isEmpty {
            settings["apiKey"] = apiKey
        }

        let transport = try OpenAIChatTransport(config: ChatTransportConfig(settings: settings), logger: LiveLogger())
        await transport.start()
        await transport.send(.prompt(text: "Reply with exactly the word: pong"))

        var text = ""
        var reasoning = ""
        var sawStart = false
        var stopReason: String?
        var usage: UsageInfo?
        var resolvedModel: String?

        let deadline = Date().addingTimeInterval(120)
        for await event in transport.events {
            switch event {
            case .sessionReady(_, let options):
                resolvedModel = options.first?.currentValue
            case .messageStart:
                sawStart = true
            case .messageDelta(_, let delta):
                text += delta
            case .thoughtDelta(_, let delta):
                reasoning += delta
            case .usage(let info):
                usage = info
            case .error(let message, _):
                XCTFail("transport error: \(message)")
            case .messageEnd(_, let reason):
                stopReason = reason
            default:
                break
            }
            if stopReason != nil {
                break
            }
            if Date() > deadline {
                XCTFail("live turn did not finish within 120s")
                break
            }
        }
        await transport.stop()

        XCTAssertTrue(sawStart, "expected the assistant message to start")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "expected non-empty assistant text")
        XCTAssertNotNil(stopReason, "expected a terminal stopReason")
        // Diagnostics for the commit note (visible with `swift test` verbose output).
        print("LIVE openai-sse: model=\(resolvedModel ?? "?") stop=\(stopReason ?? "?") reasoningChars=\(reasoning.count) usedTokens=\(usage?.used.description ?? "n/a")")
        print("LIVE openai-sse reply: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
    }
}
