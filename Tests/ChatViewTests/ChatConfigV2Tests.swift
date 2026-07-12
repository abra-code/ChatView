// Tests/ChatViewTests/ChatConfigV2Tests.swift
//
// P2 tests for the person-to-person / group (v2) config layer: the new appearance flags
// (showTimestamps with its alignment-conditional default, showAvatars, showDeliveryStatus)
// and the `features` gate object. The guardrail: a v1 (single-alignment) configuration
// keeps its exact defaults, so these are inert unless a host opts in. (The ActionUI
// attachActionID mapping and validate() handling are covered in the ActionUIChat add-on.)

import XCTest
@testable import ChatView

private final class ConfigV2Logger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

final class ChatConfigV2AppearanceTests: XCTestCase {

    private func config(_ properties: [String: Any]) -> ChatConfiguration {
        ChatConfiguration(dictionary: properties, logger: ConfigV2Logger())
    }

    // showTimestamps defaults to the alignment: ON in dual, OFF in single (so a v1 single
    // document is pixel-identical), and an explicit value always wins.
    func testShowTimestampsDefaultsToAlignment() {
        XCTAssertFalse(config([:]).showTimestamps, "single (default) alignment -> timestamps off")
        XCTAssertFalse(config(["appearance": ["alignment": "single"]]).showTimestamps)
        XCTAssertTrue(config(["appearance": ["alignment": "dual"]]).showTimestamps, "dual alignment -> timestamps on")
    }

    func testShowTimestampsExplicitOverridesTheAlignmentDefault() {
        XCTAssertTrue(config(["appearance": ["alignment": "single", "showTimestamps": true]]).showTimestamps)
        XCTAssertFalse(config(["appearance": ["alignment": "dual", "showTimestamps": false]]).showTimestamps)
    }

    func testShowAvatarsDefaultsFalseAndParses() {
        XCTAssertFalse(config([:]).showAvatars)
        XCTAssertTrue(config(["appearance": ["showAvatars": true]]).showAvatars)
    }

    func testShowDeliveryStatusDefaultsTrueAndParses() {
        XCTAssertTrue(config([:]).showDeliveryStatus)
        XCTAssertFalse(config(["appearance": ["showDeliveryStatus": false]]).showDeliveryStatus)
    }

    func testAlignmentParsesDualWithoutAffectingV1Default() {
        XCTAssertEqual(config([:]).alignment, .single)
        XCTAssertEqual(config(["appearance": ["alignment": "dual"]]).alignment, .dual)
    }
}

final class ChatConfigV2FeaturesTests: XCTestCase {

    private func config(_ properties: [String: Any]) -> ChatConfiguration {
        ChatConfiguration(dictionary: properties, logger: ConfigV2Logger())
    }

    func testFeaturesDefaultAllFalse() {
        let f = config([:]).features
        XCTAssertFalse(f.reactions)
        XCTAssertFalse(f.editing)
        XCTAssertFalse(f.deletion)
        XCTAssertFalse(f.replies)
    }

    func testFeaturesParse() {
        let f = config(["features": ["reactions": true, "editing": true, "deletion": false, "replies": true]]).features
        XCTAssertTrue(f.reactions)
        XCTAssertTrue(f.editing)
        XCTAssertFalse(f.deletion)
        XCTAssertTrue(f.replies)
    }

}

