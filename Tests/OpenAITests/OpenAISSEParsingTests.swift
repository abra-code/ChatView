// Tests/OpenAITests/OpenAISSEParsingTests.swift
//
// Pure, HTTP-free unit tests for the OpenAI transport's wire parsing: the SSE `data:` line
// extractor, the chat.completion.chunk interpreter (content / reasoning / tool_calls /
// finish_reason / usage), the usage mapper, the /models list parser, the request-body
// builder, and the tool-argument pretty-printer. These pin the wire contract; the
// end-to-end streaming / error / cancel behavior is covered separately in
// OpenAITransportTests against a URLProtocol stub.

import XCTest
@testable import ChatViewOpenAI
import ChatView

final class OpenAISSEParsingTests: XCTestCase {

    // MARK: - SSE line extraction

    func testSSEPayloadStripsDataPrefixAndFraming() {
        XCTAssertEqual(OpenAIChatTransport.ssePayload("data: {\"a\":1}"), "{\"a\":1}")
        XCTAssertEqual(OpenAIChatTransport.ssePayload("data:{\"a\":1}"), "{\"a\":1}", "the space after the colon is optional")
        XCTAssertEqual(OpenAIChatTransport.ssePayload("data: [DONE]"), "[DONE]")
        XCTAssertEqual(OpenAIChatTransport.ssePayload("data: x\r"), "x", "a trailing CR (CRLF framing) is trimmed")
    }

    func testSSEPayloadIgnoresNonDataLines() {
        XCTAssertNil(OpenAIChatTransport.ssePayload(""))
        XCTAssertNil(OpenAIChatTransport.ssePayload("event: message"))
        XCTAssertNil(OpenAIChatTransport.ssePayload(": a comment"))
        XCTAssertNil(OpenAIChatTransport.ssePayload("id: 42"))
    }

    // MARK: - Chunk interpretation

    func testParseChunkExtractsContent() {
        let chunk = OpenAIChatTransport.parseChunk([
            "choices": [["index": 0, "delta": ["content": "Hello"], "finish_reason": NSNull()]],
        ])
        XCTAssertEqual(chunk.content, "Hello")
        XCTAssertNil(chunk.reasoning)
        XCTAssertNil(chunk.finishReason)
        XCTAssertTrue(chunk.toolCalls.isEmpty)
    }

    func testParseChunkExtractsReasoningUnderBothKeys() {
        let a = OpenAIChatTransport.parseChunk(["choices": [["delta": ["reasoning_content": "thinking"]]]])
        XCTAssertEqual(a.reasoning, "thinking")
        let b = OpenAIChatTransport.parseChunk(["choices": [["delta": ["reasoning": "pondering"]]]])
        XCTAssertEqual(b.reasoning, "pondering", "the alternate `reasoning` key is also honored")
    }

    func testParseChunkExtractsFinishReason() {
        let chunk = OpenAIChatTransport.parseChunk(["choices": [["delta": [:], "finish_reason": "stop"]]])
        XCTAssertEqual(chunk.finishReason, "stop")
    }

    func testParseChunkExtractsToolCallFragments() {
        let chunk = OpenAIChatTransport.parseChunk([
            "choices": [["delta": ["tool_calls": [
                ["index": 0, "id": "call_1", "function": ["name": "get_weather", "arguments": "{\"city\":"]],
            ]]]],
        ])
        XCTAssertEqual(chunk.toolCalls.count, 1)
        let fragment = chunk.toolCalls[0]
        XCTAssertEqual(fragment.index, 0)
        XCTAssertEqual(fragment.id, "call_1")
        XCTAssertEqual(fragment.name, "get_weather")
        XCTAssertEqual(fragment.argumentsDelta, "{\"city\":")
    }

    func testParseChunkOnUsageOnlyChunkHasNoChoices() {
        // llama-server / OpenAI send a final chunk with empty choices carrying usage.
        let chunk = OpenAIChatTransport.parseChunk([
            "choices": [],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15],
        ])
        XCTAssertNil(chunk.content)
        XCTAssertEqual(chunk.usage?.used, 15)
    }

    // MARK: - Usage mapping

    func testParseUsagePrefersTotalTokens() {
        let usage = OpenAIChatTransport.parseUsage(["prompt_tokens": 100, "completion_tokens": 40, "total_tokens": 140])
        XCTAssertEqual(usage?.used, 140)
        XCTAssertNil(usage?.size, "the OpenAI wire reports no context-window size")
    }

    func testParseUsageFallsBackToPromptPlusCompletion() {
        let usage = OpenAIChatTransport.parseUsage(["prompt_tokens": 100, "completion_tokens": 40])
        XCTAssertEqual(usage?.used, 140)
    }

    func testParseUsageWithNoTokensIsNil() {
        XCTAssertNil(OpenAIChatTransport.parseUsage([:]))
    }

    // MARK: - Models list

    func testParseModelsList() {
        let data = Data(#"{"object":"list","data":[{"id":"llama-3.1"},{"id":"qwen"}]}"#.utf8)
        XCTAssertEqual(OpenAIChatTransport.parseModelsList(data), ["llama-3.1", "qwen"])
    }

    func testParseModelsListMalformedIsEmpty() {
        XCTAssertEqual(OpenAIChatTransport.parseModelsList(Data("not json".utf8)), [])
        XCTAssertEqual(OpenAIChatTransport.parseModelsList(Data(#"{"data":"nope"}"#.utf8)), [])
    }

    // MARK: - Request body

    func testChatRequestBodySetsStreamingAndModel() {
        let body = OpenAIChatTransport.chatRequestBody(
            model: "test-model",
            messages: [["role": "user", "content": "hi"]],
            params: ["temperature": 0.8])
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        XCTAssertEqual(body["temperature"] as? Double, 0.8, "params are merged in")
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1)
    }

    func testChatRequestBodyDropsZeroMaxTokens() {
        let dropped = OpenAIChatTransport.chatRequestBody(model: "m", messages: [], params: ["max_tokens": 0])
        XCTAssertNil(dropped["max_tokens"], "max_tokens 0 is the 'unlimited' sentinel and is omitted")
        let kept = OpenAIChatTransport.chatRequestBody(model: "m", messages: [], params: ["max_tokens": 256])
        XCTAssertEqual(kept["max_tokens"] as? Int, 256)
    }

    // MARK: - Tool arguments pretty-printing

    func testPrettyArgumentsFormatsValidJSON() {
        let pretty = OpenAIChatTransport.prettyArguments("{\"b\":2,\"a\":1}")
        XCTAssertEqual(pretty, "{\n  \"a\" : 1,\n  \"b\" : 2\n}", "valid JSON is pretty-printed with sorted keys")
    }

    func testPrettyArgumentsFallsBackToRawForPartialJSON() {
        XCTAssertEqual(OpenAIChatTransport.prettyArguments("{\"city\":"), "{\"city\":", "a partial stream shows raw")
    }

    func testPrettyArgumentsEmptyIsNil() {
        XCTAssertNil(OpenAIChatTransport.prettyArguments("   "))
    }
}
