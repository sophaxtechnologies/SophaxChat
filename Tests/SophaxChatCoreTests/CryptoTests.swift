// CryptoTests.swift
// SophaxChatCoreTests
//
// Tests for X3DH key agreement and Double Ratchet algorithm.
// Uses Swift Testing framework (Swift 5.10+, no Xcode required).

import Testing
import Foundation
import CryptoKit
@testable import SophaxChatCore

// MARK: - X3DH Tests

@Suite("X3DH Key Agreement")
struct X3DHTests {

    /// Verify that Alice and Bob derive the same shared secret via X3DH.
    @Test("Shared secret symmetry — with one-time prekey")
    func sharedSecretSymmetry() throws {
        let aliceIdentityDH = DHKeyPair()
        let bobIdentityDH   = DHKeyPair()
        let bobSigningKey   = SigningKeyPair()
        let bobSPK          = DHKeyPair()
        let bobOTPK         = DHKeyPair()

        let spkSignature = try bobSigningKey.privateKey.signature(for: bobSPK.publicKeyData)

        let bundle = PreKeyBundle(
            signingKeyPublic:      bobSigningKey.publicKeyData,
            dhIdentityKeyPublic:   bobIdentityDH.publicKeyData,
            signedPreKeyPublic:    bobSPK.publicKeyData,
            signedPreKeySignature: spkSignature,
            signedPreKeyId:        1,
            oneTimePreKeyPublic:   bobOTPK.publicKeyData,
            oneTimePreKeyId:       42,
            username:              "bob",
            timestamp:             Date()
        )

        let aliceResult = try X3DH.initiateSender(
            senderIdentity: aliceIdentityDH,
            recipientBundle: bundle
        )

        let bobSecret = try X3DH.initiateReceiver(
            recipientIdentityDH:     bobIdentityDH,
            recipientSignedPreKey:   bobSPK,
            recipientOneTimePreKey:  bobOTPK,
            senderIdentityDHKeyData: aliceIdentityDH.publicKeyData,
            senderEphemeralKeyData:  aliceResult.ephemeralPublicKey
        )

        let aliceBytes = aliceResult.sharedSecret.withUnsafeBytes { Data($0) }
        let bobBytes   = bobSecret.withUnsafeBytes { Data($0) }
        #expect(aliceBytes == bobBytes, "Alice and Bob must derive the same shared secret")
        #expect(aliceResult.usedOneTimePreKeyId == 42)
    }

    @Test("Shared secret symmetry — without one-time prekey")
    func sharedSecretWithoutOTPK() throws {
        let aliceIdentityDH = DHKeyPair()
        let bobIdentityDH   = DHKeyPair()
        let bobSigningKey   = SigningKeyPair()
        let bobSPK          = DHKeyPair()

        let spkSignature = try bobSigningKey.privateKey.signature(for: bobSPK.publicKeyData)

        let bundle = PreKeyBundle(
            signingKeyPublic:      bobSigningKey.publicKeyData,
            dhIdentityKeyPublic:   bobIdentityDH.publicKeyData,
            signedPreKeyPublic:    bobSPK.publicKeyData,
            signedPreKeySignature: spkSignature,
            signedPreKeyId:        1,
            oneTimePreKeyPublic:   nil,
            oneTimePreKeyId:       nil,
            username:              "bob",
            timestamp:             Date()
        )

        let aliceResult = try X3DH.initiateSender(senderIdentity: aliceIdentityDH, recipientBundle: bundle)
        let bobSecret   = try X3DH.initiateReceiver(
            recipientIdentityDH:     bobIdentityDH,
            recipientSignedPreKey:   bobSPK,
            recipientOneTimePreKey:  nil,
            senderIdentityDHKeyData: aliceIdentityDH.publicKeyData,
            senderEphemeralKeyData:  aliceResult.ephemeralPublicKey
        )

        let a = aliceResult.sharedSecret.withUnsafeBytes { Data($0) }
        let b = bobSecret.withUnsafeBytes { Data($0) }
        #expect(a == b)
        #expect(aliceResult.usedOneTimePreKeyId == nil)
    }

    @Test("Stale bundle is rejected")
    func staleBundle() throws {
        let aliceIdentityDH = DHKeyPair()
        let bobSigningKey   = SigningKeyPair()
        let bobSPK          = DHKeyPair()
        let spkSignature    = try bobSigningKey.privateKey.signature(for: bobSPK.publicKeyData)

        let bundle = PreKeyBundle(
            signingKeyPublic:      bobSigningKey.publicKeyData,
            dhIdentityKeyPublic:   DHKeyPair().publicKeyData,
            signedPreKeyPublic:    bobSPK.publicKeyData,
            signedPreKeySignature: spkSignature,
            signedPreKeyId:        1,
            oneTimePreKeyPublic:   nil, oneTimePreKeyId: nil,
            username:              "bob",
            timestamp:             Date(timeIntervalSinceNow: -90_000)  // 25h ago
        )

        #expect(throws: SophaxError.stalePreKeyBundle) {
            try X3DH.initiateSender(senderIdentity: aliceIdentityDH, recipientBundle: bundle)
        }
    }

    @Test("Invalid SPK signature is rejected")
    func invalidSignature() throws {
        let aliceIdentityDH = DHKeyPair()
        let bobSigningKey   = SigningKeyPair()
        let bobSPK          = DHKeyPair()
        let badSignature    = Data(repeating: 0xAA, count: 64)

        let bundle = PreKeyBundle(
            signingKeyPublic:      bobSigningKey.publicKeyData,
            dhIdentityKeyPublic:   DHKeyPair().publicKeyData,
            signedPreKeyPublic:    bobSPK.publicKeyData,
            signedPreKeySignature: badSignature,
            signedPreKeyId:        1,
            oneTimePreKeyPublic:   nil, oneTimePreKeyId: nil,
            username:              "bob",
            timestamp:             Date()
        )

        #expect(throws: (any Error).self) {
            try X3DH.initiateSender(senderIdentity: aliceIdentityDH, recipientBundle: bundle)
        }
    }

    @Test("Different initiations produce different secrets")
    func differentSecretsEachTime() throws {
        let bobIdentityDH = DHKeyPair()
        let bobSK         = SigningKeyPair()
        let bobSPK        = DHKeyPair()
        let spkSig        = try bobSK.privateKey.signature(for: bobSPK.publicKeyData)

        let bundle = PreKeyBundle(
            signingKeyPublic: bobSK.publicKeyData, dhIdentityKeyPublic: bobIdentityDH.publicKeyData,
            signedPreKeyPublic: bobSPK.publicKeyData, signedPreKeySignature: spkSig,
            signedPreKeyId: 1, oneTimePreKeyPublic: nil, oneTimePreKeyId: nil,
            username: "bob", timestamp: Date()
        )

        let result1 = try X3DH.initiateSender(senderIdentity: DHKeyPair(), recipientBundle: bundle)
        let result2 = try X3DH.initiateSender(senderIdentity: DHKeyPair(), recipientBundle: bundle)

        let s1 = result1.sharedSecret.withUnsafeBytes { Data($0) }
        let s2 = result2.sharedSecret.withUnsafeBytes { Data($0) }
        #expect(s1 != s2, "Different ephemeral keys must produce different secrets")
    }
}

// MARK: - Double Ratchet Tests

@Suite("Double Ratchet")
struct DoubleRatchetTests {

    /// Helper: build matched Alice/Bob session pair from a shared secret.
    func makeSessionPair() throws -> (alice: DoubleRatchet, bob: DoubleRatchet) {
        let sharedSecret = SymmetricKey(size: .bits256)
        let bobSPK       = DHKeyPair()
        let alice = try DoubleRatchet.initAsInitiator(
            sharedSecret: sharedSecret,
            remoteRatchetPublicKey: bobSPK.publicKeyData
        )
        let bob = try DoubleRatchet.initAsResponder(
            sharedSecret: sharedSecret,
            ownRatchetKeyPair: bobSPK
        )
        return (alice, bob)
    }

    @Test("Alice → Bob basic encryption")
    func basicEncryptDecrypt() throws {
        let (alice, bob) = try makeSessionPair()
        let plaintext    = Data("Hello, Bob!".utf8)
        let encrypted    = try alice.encrypt(plaintext: plaintext)
        let decrypted    = try bob.decrypt(message: encrypted)
        #expect(decrypted == plaintext)
    }

    @Test("Bob replies to Alice")
    func bobReplies() throws {
        let (alice, bob) = try makeSessionPair()
        let enc1 = try alice.encrypt(plaintext: Data("Hi".utf8))
        let _    = try bob.decrypt(message: enc1)
        let enc2 = try bob.encrypt(plaintext: Data("Hey!".utf8))
        let dec2 = try alice.decrypt(message: enc2)
        #expect(dec2 == Data("Hey!".utf8))
    }

    @Test("20 consecutive messages Alice → Bob")
    func manyMessages() throws {
        let (alice, bob) = try makeSessionPair()
        for i in 0..<20 {
            let text = "Message \(i)"
            let enc  = try alice.encrypt(plaintext: Data(text.utf8))
            let dec  = try bob.decrypt(message: enc)
            #expect(String(data: dec, encoding: .utf8) == text)
        }
    }

    @Test("10 round-trip bidirectional messages")
    func bidirectional() throws {
        let (alice, bob) = try makeSessionPair()
        for i in 0..<10 {
            let a2b = "A→B \(i)"
            let b2a = "B→A \(i)"
            let aEnc = try alice.encrypt(plaintext: Data(a2b.utf8))
            let aDec = try bob.decrypt(message: aEnc)
            #expect(String(data: aDec, encoding: .utf8) == a2b)
            let bEnc = try bob.encrypt(plaintext: Data(b2a.utf8))
            let bDec = try alice.decrypt(message: bEnc)
            #expect(String(data: bDec, encoding: .utf8) == b2a)
        }
    }

    @Test("Different messages produce different ciphertexts (unique keys/nonces)")
    func uniqueKeys() throws {
        let (alice, _) = try makeSessionPair()
        let enc1 = try alice.encrypt(plaintext: Data("same".utf8))
        let enc2 = try alice.encrypt(plaintext: Data("same".utf8))
        #expect(enc1.ciphertext != enc2.ciphertext, "Each message must use a unique key+nonce")
    }

    @Test("Out-of-order message delivery")
    func outOfOrder() throws {
        let (alice, bob) = try makeSessionPair()
        let pt0 = Data("msg0".utf8)
        let pt1 = Data("msg1".utf8)
        let pt2 = Data("msg2".utf8)

        let enc0 = try alice.encrypt(plaintext: pt0)
        let enc1 = try alice.encrypt(plaintext: pt1)
        let enc2 = try alice.encrypt(plaintext: pt2)

        // Deliver 2 → 0 → 1 (out of order)
        let dec2 = try bob.decrypt(message: enc2)
        let dec0 = try bob.decrypt(message: enc0)
        let dec1 = try bob.decrypt(message: enc1)

        #expect(dec0 == pt0)
        #expect(dec1 == pt1)
        #expect(dec2 == pt2)
    }

    @Test("Session state export/import (persistence)")
    func stateRoundtrip() throws {
        let (alice, bob) = try makeSessionPair()
        let pt  = Data("hello".utf8)
        let enc = try alice.encrypt(plaintext: pt)

        // Persist and restore Bob's state
        let stateData   = try bob.exportState()
        let restoredBob = try DoubleRatchet.importState(stateData)
        let dec         = try restoredBob.decrypt(message: enc)
        #expect(dec == pt)
    }

    @Test("Wrong associated data fails decryption")
    func wrongAD() throws {
        let (alice, bob) = try makeSessionPair()
        let enc = try alice.encrypt(plaintext: Data("hi".utf8), associatedData: Data("correct".utf8))
        #expect(throws: (any Error).self) {
            try bob.decrypt(message: enc, associatedData: Data("wrong".utf8))
        }
    }

    @Test("KDF_CK produces distinct keys at each step")
    func kdfCKDistinctKeys() {
        let ck          = SymmetricKey(size: .bits256)
        let (ck2, mk1)  = DoubleRatchet.kdfCK(ck)
        let (ck3, mk2)  = DoubleRatchet.kdfCK(ck2)

        func bytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

        #expect(bytes(ck)  != bytes(ck2),  "Chain key must change each step")
        #expect(bytes(ck2) != bytes(ck3),  "Chain key must change each step")
        #expect(bytes(ck2) != bytes(mk1),  "Chain key ≠ message key")
        #expect(bytes(mk1) != bytes(mk2),  "Consecutive message keys must differ")
    }
}
