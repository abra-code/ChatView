// Tests/ChatViewTests/ChatDualSnapshotTests.swift
//
// A developer snapshot harness (NOT a CI assertion): renders a synthesized dual-alignment
// transcript to a PNG via ImageRenderer, for eyeballing the layout during P4/P5 before the
// local-p2p transport (P6) exists. Gated on the CHAT_SNAPSHOT env var so a normal test run
// skips it. Run with: CHAT_SNAPSHOT=<dir> swift test --filter ChatDualSnapshotTests

import XCTest
import SwiftUI
@testable import ChatView

@MainActor
final class ChatDualSnapshotTests: XCTestCase {

    private final class SnapLogger: ChatLogger {
        func log(_ message: String, _ level: ChatLogLevel) {}
    }

    func testRenderDualTranscriptSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT"] else {
            throw XCTSkip("set CHAT_SNAPSHOT=<dir> to render the dual-transcript snapshot")
        }

        let config = ChatConfiguration(dictionary: [
            "appearance": ["alignment": "dual", "showRoleLabels": true, "showAvatars": true,
                           "showTimestamps": true, "showDeliveryStatus": true],
            "features": ["reactions": true, "replies": true, "editing": true, "deletion": true],
        ], logger: SnapLogger())

        func ctx(_ id: String, _ item: ChatItem, isSelf: Bool, name: String?, time: String?,
                 first: Bool = true, last: Bool = true, newDay: Bool = false) -> DualRowContext {
            DualRowContext(id: id, item: item,
                           info: ChatTranscriptLayout.Info(isFirstInRun: first, isLastInRun: last, startsNewDay: newDay),
                           isSelf: isSelf, senderName: name, avatarURL: nil,
                           timestamp: ChatTimestamp.parse(time))
        }

        func msg(_ id: String, _ role: ChatRole, _ text: String, senderID: String? = nil, name: String? = nil,
                 time: String? = nil, status: MessageStatus? = nil, editedAt: String? = nil,
                 deleted: Bool? = nil, reply: ReplyRef? = nil, reactions: [Reaction]? = nil) -> ChatItem {
            .message(ChatMessage(id: id, role: role, text: text, isStreaming: false, senderID: senderID,
                                 senderName: name, timestamp: time, status: status, reactions: reactions,
                                 editedAt: editedAt, replyTo: reply, deleted: deleted))
        }

        let rows: [DualRowContext] = [
            ctx("m1", msg("m1", .remote, "Hey! Are we still on for tomorrow?", name: "Alex", time: "2026-07-09T09:00:00Z"),
                isSelf: false, name: "Alex", time: "2026-07-09T09:00:00Z", first: true, last: false),
            ctx("m2", msg("m2", .remote, "I found a great spot for lunch.", name: "Alex", time: "2026-07-09T09:00:20Z",
                          reactions: [Reaction(emoji: "\u{1F44D}", count: 2, mine: true),
                                      Reaction(emoji: "\u{2764}\u{FE0F}", count: 1, mine: false)]),
                isSelf: false, name: "Alex", time: "2026-07-09T09:00:20Z", first: false, last: true),
            ctx("m3", msg("m3", .local, "Yes! Sounds perfect.", time: "2026-07-10T10:15:00Z", status: .read),
                isSelf: true, name: nil, time: "2026-07-10T10:15:00Z", newDay: true),
            ctx("m4", msg("m4", .local, "Let me double-check the time.", time: "2026-07-10T10:16:00Z", status: .delivered,
                          editedAt: "2026-07-10T10:17:00Z"),
                isSelf: true, name: nil, time: "2026-07-10T10:16:00Z"),
            ctx("m5", msg("m5", .remote, "Noon works for me.", name: "Alex", time: "2026-07-10T10:18:00Z",
                          reply: ReplyRef(itemID: "m4", excerpt: "Let me double-check the time.", senderName: "You")),
                isSelf: false, name: "Alex", time: "2026-07-10T10:18:00Z"),
            ctx("m6", msg("m6", .local, "", time: "2026-07-10T10:19:00Z", status: .failed),
                isSelf: true, name: nil, time: "2026-07-10T10:19:00Z"),
            ctx("m7", msg("m7", .remote, "", name: "Alex", time: "2026-07-10T10:20:00Z", deleted: true),
                isSelf: false, name: "Alex", time: "2026-07-10T10:20:00Z"),
            ctx("ev1", .memberEvent(MemberEvent(id: "ev1", kind: .joined, subjectName: "Sam")),
                isSelf: false, name: nil, time: nil),
            ctx("call1", .callEvent(CallEvent(id: "call1", kind: .missedIncoming, isVideo: true)),
                isSelf: false, name: nil, time: nil),
            ctx("file1", .file(ChatFile(id: "file1", role: .remote, senderID: "alex", senderName: "Alex",
                                        timestamp: "2026-07-10T10:22:00Z", name: "itinerary.pdf", sizeBytes: 284_160,
                                        url: URL(string: "https://ex.test/i.pdf"), kind: .file,
                                        transferStatus: .transferring, progress: 0.6)),
                isSelf: false, name: "Alex", time: "2026-07-10T10:22:00Z"),
            ctx("voice1", .file(ChatFile(id: "voice1", role: .local, senderID: "me", timestamp: "2026-07-10T10:23:00Z",
                                         name: "voice.m4a", kind: .voice, durationSeconds: 14, transferStatus: .completed)),
                isSelf: true, name: nil, time: "2026-07-10T10:23:00Z"),
        ]

        let audioController = ChatAudioController()
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    if row.info.startsNewDay, let date = row.timestamp {
                        DaySeparatorRow(date: date)
                    }
                    DualTranscriptRow(ctx: row, config: config, maxBubbleWidth: 300,
                                      showsSenderNames: true,
                                      actions: DualRowActions(canReply: true, canEdit: true, canDelete: true, canReact: true),
                                      highlighted: false, audio: audioController, onResend: { _ in })
                }
                .padding(.top, row.info.isFirstInRun ? 8 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TypingIndicatorRow(names: ["Sam"]).padding(.top, 6)
        }
        .padding(12)
        .frame(width: 460)
        .background(Color(white: 0.98))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            return XCTFail("ImageRenderer produced no image")
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encoding failed")
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("dual-transcript.png")
        try png.write(to: url)
        print("SNAPSHOT written: \(url.path)")
    }
}
