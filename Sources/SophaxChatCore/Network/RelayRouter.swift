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

public final class RelayRouter: @unchecked Sendable {

    private let maxSeen: Int
    private var seenSet:   Set<String>    = []
    private var seenQueue: [String]       = []   // FIFO for LRU eviction
    private let lock = NSLock()

    public init(maxSeen: Int = 500) {
        self.maxSeen = maxSeen
    }

    // MARK: - Public API

    /// Call this when a RelayEnvelope arrives.
    /// Returns `true` if the envelope should be processed/forwarded,
    /// `false` if it was already seen or TTL is exhausted.
    public func shouldProcess(_ envelope: RelayEnvelope) -> Bool {
        guard envelope.ttl > 0 else { return false }

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
