// Examples/ChatViewDemo/StressTransport.swift
//
// A repro harness for the transcript layout-loop crash: an uncaught AppKit exception from
// -[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]. It needs a LONG answer streamed FAST
// into a pinned viewport of AppKit-backed (RichText) rows - i.e. what a "summarize this PDF" turn
// looks like in a host - which no interactive demo screen produces on its own.
//
// The cause is a scroller-width loop, NOT a pending scroll action as this comment once claimed (see
// ChatTranscriptScroller.stabilizeScrollerWidth). To actually reproduce it, pair this with
// CHATVIEW_DEMO_LEGACY_SCROLLERS=1 and a window short enough that the transcript's height lands near
// the viewport's - on a machine with overlay scrollers, streaming alone will never trigger it.
//
// Registered under the protocol name "stress" and driven entirely from start(): the turns fire
// without a prompt, so `CHATVIEW_DEMO_SCREEN=stress swift run ChatViewDemo` is a self-running
// repro. Knobs (all optional, via the screen's transport config):
//
//   rounds   how many agent turns to run back to back (default 6) - each one grows the transcript,
//            so later rounds re-layout a taller document, which is when the guard trips
//   chunkMs  delay between streamed deltas (default 0: as fast as the main runloop drains, the
//            harshest case; a real agent lands somewhere in 1-30)
//   blocks   markdown blocks per answer (default 24) - the answer length
//   toolChars size of the tool card's content payload (default 50000, matching pdfutil's cap) - it
//            is folded in the card, so this checks the folded path really does cost nothing
//
// Nothing here is part of the library: the harness lives in the demo target so the repro ships
// with the package without widening ChatView's own surface.

import Foundation
import ChatView
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif

final class StressTransport: ChatTransport, @unchecked Sendable {

    let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let rounds: Int
    private let chunkDelay: UInt64
    private let blocks: Int
    private let toolChars: Int
    private let turnGap: UInt64
    private let lock = NSLock()
    private var driver: Task<Void, Never>?

    init(config: ChatTransportConfig) {
        rounds = config.int("rounds") ?? 6
        chunkDelay = UInt64(max(0, config.int("chunkMs") ?? 0)) * 1_000_000
        blocks = config.int("blocks") ?? 24
        toolChars = config.int("toolChars") ?? 50_000
        turnGap = UInt64(max(0, config.int("turnGapMs") ?? 0)) * 1_000_000
        var captured: AsyncStream<ChatEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
    }

    func start() async {
        note("starting: rounds=\(rounds) chunkMs=\(chunkDelay / 1_000_000) blocks=\(blocks) toolChars=\(toolChars)")
        warnIfScreenLocked()
        continuation.yield(.sessionReady(sessionID: "stress", configOptions: []))
        let task = Task { [weak self] in
            guard let self else { return }
            // A beat for the window to finish coming up, so round 1 streams into a settled view.
            try? await Task.sleep(nanoseconds: 700_000_000)
            for round in 1...rounds {
                if Task.isCancelled { return }
                await runTurn(round: round)
                // A settle gap between turns. The reported crash was a NEW TURN on a small context,
                // not one long answer, so the interesting moment is a turn STARTING against a settled
                // transcript - which a back-to-back loop never produces.
                if turnGap > 0 {
                    try? await Task.sleep(nanoseconds: turnGap)
                }
            }
            continuation.yield(.system(text: "stress: \(rounds) rounds completed without a crash"))
            note("\(rounds) rounds completed - no crash")
            // Quit when the run is done so the harness can be looped: the crash is probabilistic per
            // session (it needs the transcript to be crossing the viewport height while a turn
            // streams), so N short sessions beat one long one. CHATVIEW_STRESS_KEEP_OPEN=1 leaves the
            // window up for eyeballing instead. The settle beat lets the last layout finish, so a
            // crash that would have happened on the final turn still gets its chance.
            #if canImport(AppKit)
            if ProcessInfo.processInfo.environment["CHATVIEW_STRESS_KEEP_OPEN"] == nil {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { NSApp.terminate(nil) }
            }
            #endif
        }
        lock.withLock { driver = task }
    }

    /// Progress goes to stderr (unbuffered), so a redirected run still shows how far it got: a crash
    /// mid-round leaves the last round it reached in the log, and print() would have sat in a buffer.
    private func note(_ message: String) {
        FileHandle.standardError.write(Data("[stress] \(message)\n".utf8))
    }

    /// A locked or asleep display stops the window server from rendering this window, so SwiftUI never
    /// lays out, the turns never stream, and the run looks like a hang rather than a pass. Say so
    /// instead of leaving an idle process behind - the repro needs an unlocked, awake session.
    private func warnIfScreenLocked() {
        #if canImport(CoreGraphics)
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return }
        if session["CGSSessionScreenIsLocked"] as? Bool == true {
            note("WARNING: the screen is locked - the window will not render and nothing will stream. "
                 + "Unlock the session and run again.")
        }
        #endif
    }

    func send(_ command: ChatCommand) async {
        if case .cancel = command {
            lock.withLock { driver }?.cancel()
        }
    }

    func stop() async {
        lock.withLock { driver }?.cancel()
        continuation.finish()
    }

    /// One "summarize the document" turn: the user's ask, a tool call carrying a bulk payload, then a
    /// long markdown answer streamed delta by delta into the pinned transcript.
    private func runTurn(round: Int) async {
        let itemID = "stress-\(round)"
        continuation.yield(.messageStart(itemID: "\(itemID)-user", role: .local))
        continuation.yield(.messageDelta(itemID: "\(itemID)-user",
                                         text: "Summarize the attached document (round \(round))."))
        continuation.yield(.messageEnd(itemID: "\(itemID)-user", stopReason: "end_turn"))

        let toolID = "\(itemID)-tool"
        continuation.yield(.toolCall(ToolCallModel(
            id: toolID, title: "pdf_text report-\(round).pdf", kind: .read, status: .inProgress,
            contentText: "", diff: nil, rawInput: "{ \"path\": \"report-\(round).pdf\" }", rawOutput: nil)))
        await pause()
        continuation.yield(.toolCallUpdate(ToolCallUpdate(
            id: toolID, status: .completed, contentText: StressContent.bulk(characters: toolChars))))

        continuation.yield(.messageStart(itemID: itemID, role: .agent))
        let chunks = StressContent.answerChunks(round: round, blocks: blocks)
        note("round \(round)/\(rounds): streaming \(chunks.count) deltas")
        for chunk in chunks {
            if Task.isCancelled {
                continuation.yield(.messageEnd(itemID: itemID, stopReason: "cancelled"))
                return
            }
            await pause()
            continuation.yield(.messageDelta(itemID: itemID, text: chunk))
        }
        continuation.yield(.messageEnd(itemID: itemID, stopReason: "end_turn"))
    }

    /// One streaming beat. At chunkMs 0 this still yields, so the main runloop keeps servicing the
    /// display cycle instead of the whole answer arriving in a single update (which would test
    /// nothing - the crash needs many updates, each queueing a scroll).
    private func pause() async {
        if chunkDelay > 0 {
            try? await Task.sleep(nanoseconds: chunkDelay)
        } else {
            await Task.yield()
        }
    }
}

/// The streamed material: markdown that re-wraps hard (headings, lists, a table, code, long
/// paragraphs), chunked into word-sized deltas the way a token stream arrives.
enum StressContent {

    static func answerChunks(round: Int, blocks: Int) -> [String] {
        chunks(of: answer(round: round, blocks: blocks))
    }

    /// Word-sized deltas, whitespace preserved (so markdown structure streams faithfully).
    static func chunks(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n" {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            out.append(current)
        }
        return out
    }

    static func bulk(characters: Int) -> String {
        guard characters > 0 else { return "" }
        let unit = "The quick brown fox jumps over the lazy dog. "
        var text = ""
        while text.count < characters {
            text += unit
        }
        return String(text.prefix(characters))
    }

    static func answer(round: Int, blocks: Int) -> String {
        var parts: [String] = ["## Summary of report-\(round).pdf\n\n"]
        for index in 0..<blocks {
            switch index % 4 {
            case 0:
                parts.append("""
                The document opens with a statement of scope, then narrows to the three findings \
                that carry the rest of the argument. Section \(index + 1) restates the method in \
                enough detail to reproduce it, which is unusual for a report of this length and \
                worth noting when comparing it against the earlier revision.

                """)
            case 1:
                parts.append("""
                ### Finding \(index + 1)

                - The measured effect holds across all three cohorts.
                - The confidence interval widens sharply below the 200-sample mark.
                - Two outliers are excluded, and the exclusion is justified in an appendix.

                """)
            case 2:
                parts.append("""
                | Cohort | Samples | Effect |
                | --- | --- | --- |
                | A | 1,204 | +3.1% |
                | B | 880 | +2.7% |
                | C | 191 | +4.9% |

                """)
            default:
                parts.append("""
                ```swift
                func summarize(_ page: Page) -> Summary {
                    Summary(title: page.title, body: page.text.prefix(400))
                }
                ```

                > The appendix repeats the caveat about cohort C, whose sample count sits below \
                the threshold the method section sets for itself.

                """)
            }
        }
        return parts.joined()
    }
}
