// RelayRouterTests.swift
// SophaxChatCoreTests
//
// Unit tests for RelayRouter — deduplication, TTL enforcement, LRU eviction.

import Testing
import Foundation
@testable import SophaxChatCore

// MARK: - Helpers

private func makeEnvelope(id: String = UUID().uuidString, ttl: UInt8 = RelayEnvelope.maxTTL) -> RelayEnvelope {
    // Minimal WireMessage stub — content is irrelevant for routing tests
    let stub = WireMessage(
        type: .message, payload: Data(), senderID: "sender",
        timestamp: Date(), signature: Data()
    )
    return RelayEnvelope(
        id: id, targetPeerID: "target", originPeerID: "origin",
        ttl: ttl, hopCount: 0, message: stub
    )
}

// MARK: - Tests

@Suite("RelayRouter")
struct RelayRouterTests {

    // MARK: Basic deduplication

    @Test("First-seen envelope is processed")
    func firstSeenIsProcessed() {
        let router = RelayRouter()
        let env = makeEnvelope()
        #expect(router.shouldProcess(env) == true)
    }

    @Test("Duplicate envelope is dropped")
    func duplicateIsDropped() {
        let router = RelayRouter()
        let env = makeEnvelope()
        _ = router.shouldProcess(env)
        #expect(router.shouldProcess(env) == false)
    }

    @Test("Different IDs are processed independently")
    func differentIDsAreIndependent() {
        let router = RelayRouter()
        #expect(router.shouldProcess(makeEnvelope(id: "a")) == true)
        #expect(router.shouldProcess(makeEnvelope(id: "b")) == true)
    }

    // MARK: TTL enforcement

    @Test("Zero TTL is rejected")
    func zeroTTLRejected() {
        let router = RelayRouter()
        #expect(router.shouldProcess(makeEnvelope(ttl: 0)) == false)
    }

    @Test("Inflated TTL above maxTTL is rejected (DoS guard)")
    func inflatedTTLRejected() {
        let router = RelayRouter()
        // A malicious peer could craft ttl = 255 to cause unbounded flooding.
        #expect(router.shouldProcess(makeEnvelope(ttl: 255)) == false)
        #expect(router.shouldProcess(makeEnvelope(ttl: RelayEnvelope.maxTTL + 1)) == false)
    }

    @Test("maxTTL is accepted")
    func maxTTLAccepted() {
        let router = RelayRouter()
        #expect(router.shouldProcess(makeEnvelope(ttl: RelayEnvelope.maxTTL)) == true)
    }

    @Test("TTL of 1 is accepted")
    func ttl1Accepted() {
        let router = RelayRouter()
        #expect(router.shouldProcess(makeEnvelope(ttl: 1)) == true)
    }

    // MARK: LRU eviction

    @Test("Seen-set stays bounded by maxSeen")
    func seenSetIsBounded() {
        let max = 10
        let router = RelayRouter(maxSeen: max)
        for _ in 0..<(max + 5) {
            _ = router.shouldProcess(makeEnvelope())
        }
        #expect(router.seenCount == max)
    }

    @Test("Evicted IDs can be re-processed")
    func evictedIDsCanBeReprocessed() {
        let router = RelayRouter(maxSeen: 2)
        let first = makeEnvelope(id: "first")

        _ = router.shouldProcess(first)          // seen: [first]
        _ = router.shouldProcess(makeEnvelope()) // seen: [first, x]
        _ = router.shouldProcess(makeEnvelope()) // evicts "first", seen: [x, y]

        // "first" was evicted — should be processable again
        #expect(router.shouldProcess(first) == true)
    }

    // MARK: Reset

    @Test("Reset clears all state")
    func resetClearsState() {
        let router = RelayRouter()
        let env = makeEnvelope()
        _ = router.shouldProcess(env)
        router.reset()
        #expect(router.seenCount == 0)
        #expect(router.shouldProcess(env) == true)
    }
}
