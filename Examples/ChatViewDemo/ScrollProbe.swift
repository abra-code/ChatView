// Examples/ChatViewDemo/ScrollProbe.swift
//
// Drives the transcript with SYNTHETIC scroll-wheel gestures, so "the reader scrolls up" becomes
// something a script can test. The pin bugs that reach users are all about what happens when a real
// person scrolls a real scroll view - a wheel notch on a settled transcript, a drag against a
// streaming one - and the stress harness (StressTransport.swift) cannot produce any of that: it only
// streams content, and the pin state machine's unit tests only exercise the sample sequences a human
// has guessed at. This closes that gap: the events go through NSScrollView, so the geometry samples,
// the offset clamping and the macOS 15+ scroll PHASES are the real ones.
//
// The events are built as CGEvents and handed to the window directly (window.sendEvent), NOT posted to
// the HID tap: no accessibility permission, nothing leaks onto whatever else the user has on screen,
// and the run works headless-ish in the background.
//
//   CHATVIEW_SCROLL_PROBE=1              run the standard script (see `run`)
//   CHATVIEW_SCROLL_PROBE_DELAY_MS=6000  when to start, counted from launch - long enough that the
//                                        stress rounds have finished and the transcript is settled
//
// Each gesture brackets itself with [probe] markers on stderr, interleaved with the [pin] trace
// (CHATVIEW_PIN_TRACE=1), so a scoring script can slice the trace per gesture and ask the only two
// questions that matter: did the pin release, and did the transcript scroll itself while the reader
// was scrolling.
//
// Nothing here is part of the library.

import Foundation
#if canImport(AppKit)
import AppKit

@MainActor
enum ScrollProbe {

    /// Points per synthetic wheel event. 30 is about one notch of a real wheel / a small trackpad
    /// nudge - the size the report says was being ignored ("a small manual scroll up immediately
    /// brings it back").
    private static let notch: CGFloat = 30

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["CHATVIEW_SCROLL_PROBE"], !raw.isEmpty, raw != "0" else { return }
        let delayMs = Double(env["CHATVIEW_SCROLL_PROBE_DELAY_MS"] ?? "") ?? 6000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
            await run()
        }
    }

    private static func run() async {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            note("no visible window - nothing to scroll")
            return
        }
        describeTarget()
        // A settled transcript, one small nudge up: the exact reported case.
        await gesture("small-up", window: window, events: 1)
        // A slightly longer drag, still small in absolute terms.
        await gesture("drag-up", window: window, events: 4)
        // And back down to the bottom, which must re-pin.
        await gesture("drag-down", window: window, events: 6, direction: -1)
        note("done")
        // The probe owns termination when it runs: the stress transport's own auto-quit has to be
        // disabled (CHATVIEW_STRESS_KEEP_OPEN=1) for the transcript to still be there to scroll.
        if ProcessInfo.processInfo.environment["CHATVIEW_PROBE_KEEP_OPEN"] == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }

    /// One gesture: began, N changed, ended - the shape AppKit sees from a trackpad. `direction` +1
    /// scrolls toward older content (what a reader does to read back), -1 toward the bottom.
    private static func gesture(_ name: String, window: NSWindow, events: Int, direction: CGFloat = 1) async {
        let before = offset(in: window)
        note("gesture \(name) begin (\(events) x \(Int(notch))pt, \(direction > 0 ? "up" : "down")) offset=\(before)")
        send(phase: .began, delta: direction * notch, to: window)
        for _ in 1..<max(1, events) {
            try? await Task.sleep(nanoseconds: 16_000_000)   // ~one frame apart, like a real gesture
            send(phase: .changed, delta: direction * notch, to: window)
        }
        try? await Task.sleep(nanoseconds: 16_000_000)
        send(phase: .ended, delta: 0, to: window)
        // Let the view settle: any chase-back, re-measure or pin flip lands within a few frames.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        note("gesture \(name) end offset=\(offset(in: window))")
    }

    /// Where the scroll view actually sits. The single most useful number the probe reports: if it does
    /// not move, the synthetic event never reached the scroll view (an environment problem); if it
    /// moves and then comes back, the transcript scrolled the reader back (the bug).
    private static func offset(in window: NSWindow) -> Int {
        Int((scrollView(in: window)?.contentView.bounds.origin.y ?? -1).rounded())
    }

    private enum GesturePhase {
        case began, changed, ended

        /// kCGScrollPhase* - the field NSEvent.phase is derived from.
        var cgValue: Int64 {
            switch self {
            case .began: return 1
            case .changed: return 2
            case .ended: return 4
            }
        }
    }

    private static func send(phase: GesturePhase, delta: CGFloat, to window: NSWindow) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                   wheel1: Int32(delta), wheel2: 0, wheel3: 0) else {
            note("could not build a scroll event")
            return
        }
        scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        scroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.cgValue)
        // CGEvent locations are screen coordinates with a TOP-left origin; AppKit's are bottom-left.
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        if let primary = NSScreen.screens.first {
            scroll.location = CGPoint(x: center.x, y: primary.frame.height - center.y)
        }
        guard let event = NSEvent(cgEvent: scroll) else {
            note("could not wrap the scroll event")
            return
        }
        // Straight to the scroll view when we can find it: hit-testing depends on the window being
        // properly on screen, which is not guaranteed for an automated run (a locked session orders
        // windows out), and a dropped event looks exactly like a pin that ignored the reader.
        let target = scrollView(in: window)
        let before = target?.contentView.bounds.origin.y
        if let target {
            target.scrollWheel(with: event)
        } else {
            window.sendEvent(event)
        }
        // An occluded window (a locked session, most often) processes no scroll events at all, and a
        // probe that silently did nothing would read as a clean pass. Move the clip view ourselves
        // instead. That is a WEAKER test - it is not a real gesture, so the scroll view reports no user
        // phase and the pin falls back to its offset heuristics - but it is the honest half: something
        // moved the viewport that the transcript did not move itself, which is all the pre-macOS-15
        // path ever gets to see.
        if let target, let before, target.contentView.bounds.origin.y == before, delta != 0 {
            if !fellBack {
                fellBack = true
                note("NOTE: the window processes no scroll events (occluded / locked session). "
                     + "Falling back to moving the clip view directly - this exercises the pin's "
                     + "heuristic path only, NOT the macOS 15 user-phase path.")
            }
            let maxY = max(0, (target.documentView?.bounds.height ?? 0) - target.contentView.bounds.height)
            let y = min(maxY, max(0, before - delta))    // +delta scrolls toward older content
            target.contentView.scroll(to: CGPoint(x: 0, y: y))
            target.reflectScrolledClipView(target.contentView)
        }
    }

    private static var fellBack = false

    /// The transcript's backing NSScrollView. SwiftUI's ScrollView is an NSScrollView underneath on
    /// macOS; the transcript is the tallest one in the window (the composer has none).
    private static func scrollView(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        var found: [NSScrollView] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            stack.append(contentsOf: view.subviews)
        }
        return found.max { $0.bounds.height < $1.bounds.height }
    }

    /// One-shot report of what the probe is actually driving - without it, "no samples" is
    /// indistinguishable between "the pin ignored the scroll" and "the event never arrived".
    static func describeTarget() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            note("target: NO visible window")
            return
        }
        let scroll = scrollView(in: window)
        note("target: window \(Int(window.frame.width))x\(Int(window.frame.height)) "
             + "visible=\(window.isVisible) onScreen=\(window.occlusionState.contains(.visible)) "
             + "scrollView=\(scroll.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "NONE") "
             + "docHeight=\(scroll?.documentView.map { Int($0.bounds.height) } ?? -1)")
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("[probe] \(message)\n".utf8))
    }
}
#endif
