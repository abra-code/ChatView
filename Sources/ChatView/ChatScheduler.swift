// Sources/ChatView/ChatScheduler.swift
//
// A main-actor time source + delayed-callback scheduler, injected into ChatStore so the
// time-based person-to-person (v2) behaviors are testable with a virtual clock instead of
// real sleeps:
//   - typing auto-expiry (a per-sender 10 s failsafe against a lost "stopped typing" signal),
//   - read-mark debounce (coalesce a burst of scroll / activity into one markRead),
//   - outgoing-typing throttle (compare `now` against the last-sent instant).
//
// The production scheduler uses the wall clock and Task.sleep; the test scheduler advances
// virtual time and fires due callbacks synchronously (see ChatStore's P3 tests). This mirrors
// the coalescing timer's intent but is injectable, per the plan's requirement that the typing
// expiry / debounce / throttle all run on an injectable clock.

import Foundation

@MainActor
protocol ChatScheduler: AnyObject {
    /// The current instant. Throttles compare against this; the store never reads `Date()` directly.
    var now: Date { get }
    /// Runs `body` after `delay` seconds. A later `schedule` with the same `key` replaces the
    /// pending one (used for debounce / expiry-refresh).
    func schedule(_ key: String, after delay: TimeInterval, _ body: @escaping @MainActor () -> Void)
    /// Cancels a pending callback for `key` (a no-op when none is pending).
    func cancel(_ key: String)
}

/// The production scheduler: wall clock + one cancellable Task per key. Created by ChatStore's
/// default init argument, so existing call sites are unaffected.
@MainActor
final class RealChatScheduler: ChatScheduler {
    private var tasks: [String: Task<Void, Never>] = [:]

    var now: Date { Date() }

    func schedule(_ key: String, after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            if Task.isCancelled {
                return
            }
            self?.tasks[key] = nil
            body()
        }
    }

    func cancel(_ key: String) {
        tasks[key]?.cancel()
        tasks[key] = nil
    }
}
