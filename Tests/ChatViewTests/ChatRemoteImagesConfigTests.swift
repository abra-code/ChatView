// Tests/ChatViewTests/ChatRemoteImagesConfigTests.swift
//
// The remoteImages setting: when images in message Markdown are fetched from the network. The default keeps
// the old behavior (automatic); "on-click" and "never" are what a host sets for a model or an agent, whose
// Markdown can use an image URL to send data out, and an unrecognized value fails closed to on-click. What
// each policy does to a rendered image is RichText's to test (RichTextRemoteImagesTests); here, that the
// setting parses, defaults and maps onto it.

import XCTest
import RichText
@testable import ChatView

private final class RemoteImagesLogger: ChatLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var logged: [(String, ChatLogLevel)] = []

    var messages: [(String, ChatLogLevel)] {
        lock.lock()
        defer { lock.unlock() }
        return logged
    }

    func log(_ message: String, _ level: ChatLogLevel) {
        lock.lock()
        logged.append((message, level))
        lock.unlock()
    }
}

final class ChatRemoteImagesConfigTests: XCTestCase {

    private func config(_ properties: [String: Any], logger: RemoteImagesLogger = RemoteImagesLogger()) -> ChatConfiguration {
        ChatConfiguration(dictionary: properties, logger: logger)
    }

    func testTheDefaultIsAutomatic() {
        XCTAssertEqual(config([:]).remoteImages, .automatic, "an existing document keeps fetching as before")
        XCTAssertEqual(ChatConfiguration().remoteImages, .automatic, "and so does a programmatic host")
    }

    func testEachValueParses() {
        XCTAssertEqual(config(["remoteImages": "automatic"]).remoteImages, .automatic)
        XCTAssertEqual(config(["remoteImages": "on-click"]).remoteImages, .onClick)
        XCTAssertEqual(config(["remoteImages": "never"]).remoteImages, .never)
    }

    func testAnUnknownValueFailsClosedAndSaysSo() {
        // Whoever set the key meant to restrict fetching; a typo must not turn the protection off.
        let logger = RemoteImagesLogger()
        XCTAssertEqual(config(["remoteImages": "onClick"], logger: logger).remoteImages, .onClick)
        XCTAssertEqual(logger.messages.count, 1)
        XCTAssertEqual(logger.messages.first?.1, .warning)
        XCTAssertTrue(logger.messages.first?.0.contains("on-click") == true, "the warning names the accepted spelling")
        XCTAssertEqual(config(["remoteImages": "off"]).remoteImages, .onClick)
    }

    func testAWrongTypeFailsClosed() {
        XCTAssertEqual(config(["remoteImages": true]).remoteImages, .onClick)
        XCTAssertEqual(config(["remoteImages": false]).remoteImages, .onClick)
    }

    func testEachSettingMapsToTheRichTextPolicy() {
        XCTAssertEqual(ChatConfiguration.RemoteImages.automatic.richText, RichTextRemoteImages.automatic)
        XCTAssertEqual(ChatConfiguration.RemoteImages.onClick.richText, RichTextRemoteImages.onClick)
        XCTAssertEqual(ChatConfiguration.RemoteImages.never.richText, RichTextRemoteImages.never)
    }

    func testTheMemberwiseInitializerTakesIt() {
        XCTAssertEqual(ChatConfiguration(remoteImages: .onClick).remoteImages, .onClick)
    }
}
