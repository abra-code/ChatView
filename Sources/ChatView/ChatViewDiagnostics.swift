// Sources/ChatView/ChatViewDiagnostics.swift
//
// Field diagnostics for the intermittent "message text draws shifted down / outside its bubble" bug.
// RichText instruments the AppKit side (its text views cross-check frame / bounds / layer / TextKit
// geometry before every draw - see RichTextDiagnostics there). This is the SwiftUI side of the same
// investigation: it records where the transcript LAYOUT actually put each row, so a glitched frame can
// be split into "SwiftUI placed the row wrong" (rows overlap here too) vs "SwiftUI placed it right but
// the text view draws elsewhere" (rows clean here, RichText dump shows the divergence).
//
//   - Each transcript row (flag-gated) reports its frame in the transcript's own coordinate space -
//     scroll-invariant, so rects only change on real layout changes - plus the global rect at capture
//     time for correlating with RichText's window-coordinate dumps.
//   - An overlap detector checks consecutive rows (sorted by y) after each layout settles and logs an
//     error when two rows' LAYOUT rects intersect - which would prove the shift originates in the
//     transcript layout, not in the text view's drawing.
//
// Enable with env CHATVIEW_DIAGNOSTICS=1 (the row modifiers are not attached at all when disabled).
// Deliberately env-only: no UserDefaults read, so the transcript never touches CFPreferences / the
// file system just by rendering. Watch with:
//   log stream --level debug --predicate 'subsystem == "com.abracode.ChatView"'

import SwiftUI
import os

@MainActor
enum ChatViewDiagnostics {

    static let enabled: Bool = {
        guard let env = ProcessInfo.processInfo.environment["CHATVIEW_DIAGNOSTICS"] else {
            return false
        }
        return !env.isEmpty && env != "0"
    }()

    /// The transcript content's named coordinate space (origin at the top of the LazyVStack content,
    /// unaffected by scrolling). Row rects are recorded in this space.
    static let transcriptSpace = "ChatViewTranscript"

    private static let log = Logger(subsystem: "com.abracode.ChatView", category: "LayoutShift")

    private struct RowRecord {
        var content: CGRect
        var global: CGRect
        var descriptor: String
    }

    private static var rows: [String: RowRecord] = [:]
    private static var reportedOverlaps: Set<String> = []
    private static var checkScheduled = false

    /// A short, log-friendly description of a transcript item (kind, role, length, streaming state).
    static func describe(_ item: ChatItem) -> String {
        switch item {
        case .message(let message):
            return "message(\(message.role) len=\(message.text.count)\(message.isStreaming ? " streaming" : ""))"
        case .thought(let thought):
            return "thought(len=\(thought.text.count)\(thought.isStreaming ? " streaming" : ""))"
        case .toolCall(let call):
            return "toolCall(\(call.title))"
        case .image(_, let role, _):
            return "image(\(role))"
        case .system:
            return "system"
        case .error:
            return "error"
        case .memberEvent:
            return "memberEvent"
        case .callEvent:
            return "callEvent"
        case .file:
            return "file"
        case .sessionEvent(let event):
            return "sessionEvent(\(event.kind.rawValue))"
        }
    }

    static func recordRow(id: String, descriptor: String, content: CGRect, global: CGRect) {
        if let existing = rows[id], approxEqual(existing.content, content) {
            return
        }
        rows[id] = RowRecord(content: content, global: global, descriptor: descriptor)
        log.debug("row \(descriptor, privacy: .public) id=\(id, privacy: .public) content=\(fmt(content), privacy: .public) global=\(fmt(global), privacy: .public)")
        // Defer the overlap check one runloop turn so every row touched by this layout pass has
        // reported its new rect first - checking mid-pass would compare fresh rects against stale ones.
        if !checkScheduled {
            checkScheduled = true
            DispatchQueue.main.async {
                checkScheduled = false
                checkOverlaps()
            }
        }
    }

    static func removeRow(id: String) {
        rows.removeValue(forKey: id)
    }

    /// Rows stacked by the LazyVStack must not intersect. An overlap in these SwiftUI-reported rects
    /// means the transcript LAYOUT itself is wrong - the key discriminator against a drawing-side
    /// shift, where these rects stay clean. Each row is checked against the next TWO below it (a large
    /// shift can clear its immediate neighbor and land on the one after). The dedup signature buckets
    /// the overlap to 10pt so a drifting animation does not spawn a new signature per frame.
    private static func checkOverlaps() {
        let sorted = rows.sorted { $0.value.content.minY < $1.value.content.minY }
        guard sorted.count > 1 else {
            return
        }
        for index in 0..<(sorted.count - 1) {
            for offset in 1...2 where index + offset < sorted.count {
                let upper = sorted[index]
                let lower = sorted[index + offset]
                let intersection = upper.value.content.intersection(lower.value.content)
                guard intersection.height > 1, intersection.width > 1 else {
                    continue
                }
                let signature = "\(upper.key)|\(lower.key)|\(Int(intersection.height / 10))"
                guard reportedOverlaps.insert(signature).inserted else {
                    continue
                }
                if reportedOverlaps.count > 200 {
                    reportedOverlaps.removeAll()
                }
                log.error("ROW OVERLAP \(upper.value.descriptor, privacy: .public) id=\(upper.key, privacy: .public) \(fmt(upper.value.content), privacy: .public) intersects \(lower.value.descriptor, privacy: .public) id=\(lower.key, privacy: .public) \(fmt(lower.value.content), privacy: .public) by \(fmt(intersection.height), privacy: .public)pt")
            }
        }
    }

    // MARK: - Scroll-pin trace

    /// Enable with env CHATVIEW_PIN_TRACE=1 (independent of CHATVIEW_DIAGNOSTICS - the pin trace is
    /// noisy and answers a different question: why the transcript stopped following a stream, or how
    /// many scrolls a display cycle absorbed before AppKit's layout guard fired).
    static let pinTraceEnabled: Bool = {
        guard let env = ProcessInfo.processInfo.environment["CHATVIEW_PIN_TRACE"] else {
            return false
        }
        return !env.isEmpty && env != "0"
    }()

    private static let pinLog = Logger(subsystem: "com.abracode.ChatView", category: "ScrollPin")

    /// One geometry sample and what the pin state machine did with it. Goes to os_log AND stderr:
    /// stderr keeps a redirected run readable, and survives a crash without a log-stream attached.
    static func pinSample(decision: String, pinned: Bool, distanceFromBottom: CGFloat,
                          contentHeight: CGFloat, containerHeight: CGFloat, userScrollUp: CGFloat) {
        guard pinTraceEnabled else { return }
        let line = "pin \(decision) pinned=\(pinned) gap=\(fmt(distanceFromBottom)) "
            + "content=\(fmt(contentHeight)) container=\(fmt(containerHeight)) up=\(fmt(userScrollUp))"
        pinLog.debug("\(line, privacy: .public)")
        FileHandle.standardError.write(Data("[pin] \(line)\n".utf8))
    }

    /// A scroll actually issued at the transcript (which edge asked for it), so the trace shows how
    /// many scrolls one settle produced.
    static func pinScroll(_ source: String) {
        guard pinTraceEnabled else { return }
        pinLog.debug("scroll \(source, privacy: .public)")
        FileHandle.standardError.write(Data("[pin] scroll \(source)\n".utf8))
    }

    private static func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private static func fmt(_ rect: CGRect) -> String {
        "(\(fmt(rect.origin.x)),\(fmt(rect.origin.y)) \(fmt(rect.width))x\(fmt(rect.height)))"
    }
}

extension View {
    /// Attaches the row-geometry recorder when diagnostics are enabled; the exact identity view
    /// (no extra modifiers) otherwise, so normal runs are structurally unchanged.
    @ViewBuilder
    func chatRowDiagnostics(id: String, descriptor: String) -> some View {
        if ChatViewDiagnostics.enabled {
            background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            ChatViewDiagnostics.recordRow(
                                id: id, descriptor: descriptor,
                                content: geometry.frame(in: .named(ChatViewDiagnostics.transcriptSpace)),
                                global: geometry.frame(in: .global))
                        }
                        .onChange(of: geometry.frame(in: .named(ChatViewDiagnostics.transcriptSpace))) { _, newValue in
                            ChatViewDiagnostics.recordRow(
                                id: id, descriptor: descriptor,
                                content: newValue,
                                global: geometry.frame(in: .global))
                        }
                        .onDisappear {
                            ChatViewDiagnostics.removeRow(id: id)
                        }
                }
            )
        } else {
            self
        }
    }
}
