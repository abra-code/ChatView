package com.abracode.chatview

// Port of Sources/ChatView/ChatScheduler.swift.
//
// A main-confined time source + delayed-callback scheduler, injected into ChatStore so the time-based
// person-to-person (v2) behaviors are testable with a virtual clock instead of real sleeps:
//   - typing auto-expiry (a per-sender 10 s failsafe against a lost "stopped typing" signal),
//   - read-mark debounce (coalesce a burst of scroll / activity into one markRead),
//   - outgoing-typing throttle (compare `now` against the last-sent instant).
//
// The production scheduler uses the wall clock and coroutine delays; the test path drives it with
// kotlinx-coroutines-test virtual time (see the A5 store tests). The 50 ms stream-flush coalescing does NOT go
// through this scheduler (it is a raw delayed task, mirroring Swift).

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import kotlin.time.Duration

interface ChatScheduler {
    /** The current instant. Throttles compare against this; the store never reads the wall clock directly. */
    val now: Instant

    /**
     * Runs `body` after `delay`. A later `schedule` with the same `key` replaces the pending one (used for debounce /
     * expiry-refresh).
     */
    fun schedule(key: String, after: Duration, body: () -> Unit)

    /** Cancels a pending callback for `key` (a no-op when none is pending). */
    fun cancel(key: String)
}

/**
 * The production scheduler: wall clock + one cancellable coroutine per key.
 *
 * CONTRACT: `scope` MUST be confined to a single thread (the main thread), e.g. built on Dispatchers.Main.immediate,
 * mirroring the Swift @MainActor scheduler. The `jobs` map is deliberately unsynchronized: both the caller's
 * `schedule` / `cancel` and the coroutine body's `jobs.remove(key)` run on that one confined dispatcher, so there is
 * no concurrent access. The store (A5) is main-confined and supplies such a scope; a multi-threaded scope would race
 * the map.
 */
class RealChatScheduler(private val scope: CoroutineScope) : ChatScheduler {
    private val jobs = mutableMapOf<String, Job>()

    override val now: Instant get() = Instant.now()

    override fun schedule(key: String, after: Duration, body: () -> Unit) {
        jobs[key]?.cancel()
        jobs[key] = scope.launch {
            delay(if (after.isNegative()) Duration.ZERO else after)
            jobs.remove(key)
            body()
        }
    }

    override fun cancel(key: String) {
        jobs.remove(key)?.cancel()
    }
}
