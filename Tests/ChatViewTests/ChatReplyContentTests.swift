// Tests/ChatViewTests/ChatReplyContentTests.swift
//
// Unit tests for the `local` transport's canned reply content: the two reply styles (echo,
// markdown) and the word-preserving streaming chunker (chunks must reassemble to the source
// exactly, so blank lines / indentation / code layout stream faithfully). Message Markdown
// rendering itself is provided by the RichText component (covered by its own test suite and
// verified visually in the demo apps), so these tests cover only ActionUIChat's own transport logic.

import XCTest
import CoreGraphics
@testable import ChatView

final class ChatReplyContentTests: XCTestCase {

    func testStreamingChunksReassembleExactly() {
        let source = ChatReplyContent.make(style: "markdown", prompt: "hi there")
        let chunks = ChatReplyContent.streamingChunks(source)
        XCTAssertTrue(chunks.count > 1)
        XCTAssertEqual(chunks.joined(), source, "streaming chunks must reproduce the source exactly")
    }

    func testEchoReplyIsPlain() {
        XCTAssertEqual(ChatReplyContent.make(style: "echo", prompt: "ping"), "You said: ping")
    }

    // The markdown showcase reply must itself be multi-block Markdown (a heading, a fenced code
    // block, a GFM table, and a list) so it exercises RichText's block rendering in the demo.
    func testMarkdownShowcaseIsMultiBlock() {
        let source = ChatReplyContent.make(style: "markdown", prompt: "demo")
        XCTAssertTrue(source.contains("## "), "expected an ATX heading")
        XCTAssertTrue(source.contains("```"), "expected a fenced code block")
        XCTAssertTrue(source.contains("|"), "expected a GFM table")
        XCTAssertTrue(source.contains("\n- "), "expected an unordered list")
    }

    // The demo image element carries a declared pixel size (so the transcript reserves the box and does not
    // reflow on hydration) and a seeded, stable https URL.
    func testSampleImageIsSeededWithDeclaredSize() throws {
        let image = try XCTUnwrap(ChatReplyContent.sampleImage(seed: "agent-1"))
        XCTAssertEqual(image.pixelSize, CGSize(width: 480, height: 320))
        XCTAssertEqual(image.url.scheme, "https")
        XCTAssertTrue(image.url.absoluteString.contains("agent-1"), "the seed should key the URL to a stable image")
    }

    func testImageItemExposesItsID() {
        let url = URL(string: "https://example.test/i.png")!
        let item = ChatItem.image(id: "x-image", role: .agent, image: ChatImage(url: url))
        XCTAssertEqual(item.id, "x-image")
    }
}
