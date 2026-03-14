// RelayRouter.swift
// SophaxChatCore
//
// Deduplication and TTL management for the multihop relay system.
//
// When a node receives a RelayEnvelope it:
//   1. Checks if the envelope ID is in the seen-set (dedup)
//   2. If not seen AND TTL > 0: adds to seen-set, forwards decremented envelope
//   3. If already seen OR TTL == 0: drops silently
//
// The seen-set is an in-memory LRU cache bounded to `maxSeen` entries.
// This prevents a single malicious peer from exhausting memory by replaying
// old envelopes with large IDs.

import Foundation

// Threading: RelayRouter is internally thread-safe — all mutable state is protected
// by `lock` (NSLock). It is @unchecked Sendable only because NSLock is not Sendable
// in the Swift 6 type system; the implementation is safe for concurrent use.
public final class RelayRouter: @unchecked Sendable {

    private let maxSeen: Int
    private var seenSet:   Set<String>    = []
    private var seenQueue: [String]       = []   // FIFO for LRU eviction
    private let lock = NSLock()

    // MARK: - Rate limiting (per relay sender)

    /// Sliding window: max `maxRelaysPerWindow` relay forwards from one peer per `windowSeconds`.
    private let maxRelaysPerWindow: Int
    private let windowSeconds: TimeInterval
    private struct SenderWindow { var count: Int; var windowStart: Date }
    private var senderWindows: [String: SenderWindow] = [:]

    public init(maxSeen: Int = 500, maxRelaysPerWindow: Int = 20, windowSeconds: TimeInterval = 10) {
        self.maxSeen = maxSeen
        self.maxRelaysPerWindow = maxRelaysPerWindow
        self.windowSeconds = windowSeconds
    }

    // MARK: - Public API

    /// Call this when a RelayEnvelope arrives.
    /// Returns `true` if the envelope should be processed/forwarded,
    /// `false` if it was already seen or TTL is exhausted.
    public func shouldProcess(_ envelope: RelayEnvelope) -> Bool {
        // Drop if TTL exhausted OR if a malicious peer crafted an inflated TTL
        // that would cause unbounded flooding across the mesh.
        guard envelope.ttl > 0, envelope.ttl <= RelayEnvelope.maxTTL else { return false }

        lock.lock()
        defer { lock.unlock() }

        guard !seenSet.contains(envelope.id) else { return false }

        seenSet.insert(envelope.id)
        seenQueue.append(envelope.id)

        // Evict oldest entry if we've exceeded the cap
        if seenSet.count > maxSeen {
            let evicted = seenQueue.removeFirst()
            seenSet.remove(evicted)
        }
        return true
    }

    /// Returns `true` if `senderID` has exceeded the relay rate limit.
    /// Must be called under `lock`.
    public func isRateLimited(senderID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if var window = senderWindows[senderID] {
            if now.timeIntervalSince(window.windowStart) >= windowSeconds {
                // Window expired — reset
                window = SenderWindow(count: 1, windowStart: now)
                senderWindows[senderID] = window
                return false
            }
            if window.count >= maxRelaysPerWindow {
                return true   // Rate limited
            }
            window.count += 1
            senderWindows[senderID] = window
            return false
        } else {
            senderWindows[senderID] = SenderWindow(count: 1, windowStart: now)
            return false
        }
    }

    /// Remove all seen entries. Useful for testing.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        seenSet.removeAll()
        seenQueue.removeAll()
    }

    /// Number of unique relay IDs currently tracked.
    public var seenCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return seenSet.count
    }
}
