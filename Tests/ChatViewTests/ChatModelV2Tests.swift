// Tests/ChatViewTests/ChatModelV2Tests.swift
//
// P1 tests for the additive person-to-person / group (v2) model layer: the new ChatMessage
// fields (sender identity, timestamp, delivery status, reactions, edited, replyTo, tombstone),
// the new ChatItem cases (memberEvent, callEvent, file / voice), the transcript `participants`
// roster + version handling, and the ChatTransportCapabilities defaults. The cardinal constraint
// is ADDITIVE: a v1 value must serialize byte-identically to before and a v1 document must still
// decode with every v2 field absent / nil. These tests sit ALONGSIDE ChatTranscriptTests (the v1
// suite), which is left untouched and must stay green.

import XCTest
import CoreGraphics
@testable import ChatView

// MARK: - v1 byte-identity (the additive guardrail)

final class ChatModelV2ByteIdentityTests: XCTestCase {

    /// A v1 message (no v2 fields set) must encode to EXACTLY the v1 shape - only id / role / text.
    /// If any v2 key leaks into the encoding of a plain message, the v1 wire format has drifted.
    func testV1MessageEncodesWithoutAnyV2Keys() throws {
        let message = ChatMessage(id: "u1", role: .local, text: "Hi", isStreaming: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(message), encoding: .utf8)
        XCTAssertEqual(json, #"{"id":"u1","role":"local","text":"Hi"}"#,
                       "a v1 message must not emit senderID/timestamp/status/... when they are nil")
    }

    /// A v1 transcript (no participants, default version) must keep the pinned v1 JSON shape:
    /// no `participants` key, `version` still 1. This mirrors ChatTranscriptTests.testV1JSONShapeIsPinned
    /// and guards that adding the roster / version-2 support did not change the v1 encoding.
    func testV1TranscriptShapeIsUnchanged() throws {
        let transcript = ChatTranscript(items: [
            .message(ChatMessage(id: "u1", role: .local, text: "Hi", isStreaming: false)),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(transcript), encoding: .utf8)
        XCTAssertEqual(json, #"{"items":[{"message":{"id":"u1","role":"local","text":"Hi"},"type":"message"}],"version":1}"#)
    }

    /// A v1 JSON document (only id/role/text) still decodes: every v2 field comes back nil.
    func testV1MessageJSONDecodesWithNilV2Fields() throws {
        let data = Data(#"{"id":"u1","role":"remote","text":"hello"}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(message.id, "u1")
        XCTAssertEqual(message.role, .remote)
        XCTAssertNil(message.senderID)
        XCTAssertNil(message.timestamp)
        XCTAssertNil(message.status)
        XCTAssertNil(message.reactions)
        XCTAssertNil(message.editedAt)
        XCTAssertNil(message.replyTo)
        XCTAssertNil(message.deleted)
    }
}

// MARK: - v2 round-trips

final class ChatModelV2RoundTripTests: XCTestCase {

    func testMessageWithAllV2FieldsRoundTrips() throws {
        let message = ChatMessage(
            id: "m1", role: .remote, text: "See attached", isStreaming: false,
            senderID: "p2", senderName: "Alex", avatarURL: "https://ex.test/a.png",
            timestamp: "2026-07-10T12:00:00Z", status: .read,
            reactions: [Reaction(emoji: "👍", count: 2, mine: true), Reaction(emoji: "❤️", count: 1, mine: false)],
            editedAt: "2026-07-10T12:01:00Z",
            replyTo: ReplyRef(itemID: "m0", excerpt: "prior", senderName: "Me"),
            deleted: false)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        // isStreaming is never serialized, so compare it away by re-normalizing.
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.status, .read)
        XCTAssertEqual(decoded.reactions?.count, 2)
        XCTAssertEqual(decoded.replyTo?.itemID, "m0")
    }

    func testMemberEventRoundTrips() throws {
        let item = ChatItem.memberEvent(MemberEvent(
            id: "ev1", timestamp: "2026-07-10T12:00:00Z", kind: .renamed,
            actorName: "Alex", subjectName: "Group", detail: "Weekend Trip"))
        let decoded = try JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        guard case .memberEvent(let event) = decoded else { return XCTFail("expected memberEvent") }
        XCTAssertEqual(event.kind, .renamed)
        XCTAssertEqual(event.detail, "Weekend Trip")
    }

    func testCallEventRoundTrips() throws {
        let item = ChatItem.callEvent(CallEvent(
            id: "call1", timestamp: "2026-07-10T12:00:00Z", kind: .completed,
            durationSeconds: 143, isVideo: true))
        let decoded = try JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        guard case .callEvent(let event) = decoded else { return XCTFail("expected callEvent") }
        XCTAssertEqual(event.durationSeconds, 143)
        XCTAssertEqual(event.isVideo, true)
    }

    func testFileItemRoundTrips() throws {
        let item = ChatItem.file(ChatFile(
            id: "f1", role: .local, senderID: "me", senderName: "Me",
            timestamp: "2026-07-10T12:00:00Z", status: .sent, name: "report.pdf",
            sizeBytes: 20480, url: URL(string: "file:///tmp/report.pdf"), kind: .file,
            durationSeconds: nil, transferStatus: .transferring, progress: 0.42))
        let decoded = try JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        guard case .file(let file) = decoded else { return XCTFail("expected file") }
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.transferStatus, .transferring)
        XCTAssertEqual(file.progress, 0.42)
    }

    func testVoiceFileItemRoundTrips() throws {
        let item = ChatItem.file(ChatFile(
            id: "v1", role: .remote, name: "voice.m4a", sizeBytes: 8192,
            url: URL(string: "https://ex.test/v.m4a"), kind: .voice,
            durationSeconds: 12, transferStatus: .completed))
        let decoded = try JSONDecoder().decode(ChatItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        guard case .file(let file) = decoded else { return XCTFail("expected file") }
        XCTAssertEqual(file.kind, .voice)
        XCTAssertEqual(file.durationSeconds, 12)
    }

    /// `ChatFile.kind` and `.transferStatus` default when absent (kind -> file, transferStatus ->
    /// completed), so a minimally-specified file document decodes sensibly.
    func testFileKindAndTransferStatusDefaultWhenAbsent() throws {
        let data = Data(#"{"type":"file","file":{"id":"f2","role":"remote","name":"x.txt"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatItem.self, from: data)
        guard case .file(let file) = decoded else { return XCTFail("expected file") }
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.transferStatus, .completed)
        XCTAssertNil(file.progress)
    }
}

// MARK: - Transcript roster + version

final class ChatModelV2TranscriptTests: XCTestCase {

    /// A v2 transcript (participants + v2 items + version 2) round-trips completely.
    func testV2TranscriptRoundTrips() throws {
        let transcript = ChatTranscript(
            version: 2,
            items: [
                .message(ChatMessage(id: "m1", role: .remote, text: "Hi", isStreaming: false,
                                     senderID: "p2", timestamp: "2026-07-10T12:00:00Z", status: .delivered)),
                .memberEvent(MemberEvent(id: "ev1", kind: .joined, subjectName: "Sam")),
                .callEvent(CallEvent(id: "c1", kind: .missedIncoming)),
                .file(ChatFile(id: "f1", role: .local, name: "a.pdf", transferStatus: .completed)),
            ],
            participants: [
                Participant(id: "me", name: "Me", isSelf: true),
                Participant(id: "p2", name: "Alex", avatarURL: "https://ex.test/a.png"),
            ])
        let decoded = try JSONDecoder().decode(ChatTranscript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(decoded, transcript)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.participants?.count, 2)
        XCTAssertEqual(decoded.participants?.first?.isSelf, true)
    }

    /// The decoder accepts both version 1 and version 2 (v1 = participants / v2 fields absent).
    func testDecoderAcceptsVersion1And2() throws {
        let v1 = try JSONDecoder().decode(ChatTranscript.self,
            from: Data(#"{"version":1,"items":[{"type":"system","id":"s","text":"hi"}]}"#.utf8))
        XCTAssertEqual(v1.version, 1)
        XCTAssertNil(v1.participants)

        let v2 = try JSONDecoder().decode(ChatTranscript.self,
            from: Data(#"{"version":2,"items":[],"participants":[{"id":"p1","name":"Alex"}]}"#.utf8))
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(v2.participants?.first?.name, "Alex")
    }

    /// A v2 document restores through the same `ChatTranscript.decode(from:)` path the store uses
    /// for states["content"] restore (a JSON string and a dictionary).
    func testV2RestoreThroughDecodeFrom() {
        let string = #"{"version":2,"items":[{"type":"memberEvent","memberEvent":{"id":"ev1","kind":"joined","subjectName":"Sam"}}],"participants":[{"id":"me","name":"Me","isSelf":true}]}"#
        let decoded = ChatTranscript.decode(from: string)
        XCTAssertEqual(decoded?.version, 2)
        XCTAssertEqual(decoded?.participants?.count, 1)
        guard case .memberEvent(let event)? = decoded?.items.first else { return XCTFail("expected memberEvent") }
        XCTAssertEqual(event.subjectName, "Sam")
    }
}

// MARK: - Value-type helpers + capabilities

final class ChatModelV2ValueTests: XCTestCase {

    /// The delivery ladder ranks `sending` < `sent` < `delivered` < `read`; `failed` sits outside
    /// it (nil rank), so a watermark never advances to / past a failed message.
    func testMessageStatusWatermarkLadder() {
        XCTAssertLessThan(MessageStatus.sending.watermarkRank!, MessageStatus.sent.watermarkRank!)
        XCTAssertLessThan(MessageStatus.sent.watermarkRank!, MessageStatus.delivered.watermarkRank!)
        XCTAssertLessThan(MessageStatus.delivered.watermarkRank!, MessageStatus.read.watermarkRank!)
        XCTAssertNil(MessageStatus.failed.watermarkRank, "failed is outside the ladder")
    }

    func testMessageStatusRawValues() {
        // The raw values are the exact wire strings the ports and transports share.
        XCTAssertEqual(MessageStatus.sending.rawValue, "sending")
        XCTAssertEqual(MessageStatus.sent.rawValue, "sent")
        XCTAssertEqual(MessageStatus.delivered.rawValue, "delivered")
        XCTAssertEqual(MessageStatus.read.rawValue, "read")
        XCTAssertEqual(MessageStatus.failed.rawValue, "failed")
    }

    /// A transport that does not override `capabilities` advertises none - so the store never
    /// emits a v2 command to a v1 transport.
    func testDefaultTransportCapabilitiesAreAllFalse() {
        let caps = ChatTransportCapabilities()
        XCTAssertFalse(caps.paging)
        XCTAssertFalse(caps.typing)
        XCTAssertFalse(caps.reactions)
        XCTAssertFalse(caps.editing)
        XCTAssertFalse(caps.deletion)
        XCTAssertFalse(caps.replies)
        XCTAssertFalse(caps.readReceipts)
        XCTAssertFalse(caps.fileTransfer)
        XCTAssertFalse(caps.messageIdentity)
        XCTAssertFalse(caps.reportsConnectionState)
    }

    /// The connection-state raw values are the wire strings a reporting transport and the store share.
    func testConnectionStateRawValuesRoundTrip() throws {
        for state in [ChatConnectionState.connecting, .connected, .reconnecting, .offline] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(ChatConnectionState.self, from: data)
            XCTAssertEqual(decoded, state)
        }
        XCTAssertEqual(ChatConnectionState.connecting.rawValue, "connecting")
        XCTAssertEqual(ChatConnectionState.connected.rawValue, "connected")
        XCTAssertEqual(ChatConnectionState.reconnecting.rawValue, "reconnecting")
        XCTAssertEqual(ChatConnectionState.offline.rawValue, "offline")
    }
}
