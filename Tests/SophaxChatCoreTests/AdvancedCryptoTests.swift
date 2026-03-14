// AdvancedCryptoTests.swift
// SophaxChatCoreTests
//
// Tests for:
//   • Sealed sender (ECDH + HKDF + ChaCha20-Poly1305 envelope)
//   • Double Ratchet header encryption opacity (encrypted headers are opaque)
//   • Group Sender Key ratchet (HMAC-SHA256 chain advancement)

import Testing
import Foundation
import CryptoKit
@testable import SophaxChatCore

// MARK: - Sealed Sender Tests

@Suite("Sealed Sender")
struct SealedSenderTests {

    /// Replicates the sealWireMessage / unsealMessage logic from ChatManager
    /// so we can test the crypto primitive independently of the private functions.
    private func seal(_ payload: Data, recipientPublicKeyData: Data) throws -> (ephemeralPublicKey: Data, encryptedPayload: Data) {
        let ephPair  = DHKeyPair()
        let recipKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKeyData)
        let shared   = try ephPair.privateKey.sharedSecretFromKeyAgreement(with: recipKey)
        var ikmData  = Data(); shared.withUnsafeBytes { ikmData.append(contentsOf: $0) }
        let key      = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikmData),
                                               info: CryptoConstants.sealedSenderInfo,
                                               outputByteCount: 32)
        let nonce  = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(payload, using: key, nonce: nonce, authenticating: Data())
        return (ephPair.publicKeyData, sealed.combined)
    }

    private func unseal(ephemeralPublicKey: Data, encryptedPayload: Data,
                        recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        let ephKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKey)
        let shared = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephKey)
        var ikmData = Data(); shared.withUnsafeBytes { ikmData.append(contentsOf: $0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikmData),
                                          info: CryptoConstants.sealedSenderInfo,
                                          outputByteCount: 32)
        let box  = try ChaChaPoly.SealedBox(combined: encryptedPayload)
        return try ChaChaPoly.open(box, using: key, authenticating: Data())
    }

    @Test("Seal → unseal round-trip restores plaintext")
    func sealUnsealRoundtrip() throws {
        let recipient = DHKeyPair()
        let plaintext = Data("SophaxChat sealed sender test".utf8)

        let (ephPub, ciphertext) = try seal(plaintext, recipientPublicKeyData: recipient.publicKeyData)
        let recovered = try unseal(ephemeralPublicKey: ephPub, encryptedPayload: ciphertext,
                                   recipientPrivateKey: recipient.privateKey)

        #expect(recovered == plaintext, "Unsealed bytes must equal original plaintext")
    }

    @Test("Wrong recipient key fails to unseal")
    func wrongKeyFails() throws {
        let recipient = DHKeyPair()
        let attacker  = DHKeyPair()
        let plaintext = Data("secret".utf8)

        let (ephPub, ciphertext) = try seal(plaintext, recipientPublicKeyData: recipient.publicKeyData)

        #expect(throws: (any Error).self) {
            _ = try unseal(ephemeralPublicKey: ephPub, encryptedPayload: ciphertext,
                           recipientPrivateKey: attacker.privateKey)
        }
    }

    @Test("Different seals of same plaintext produce different ciphertexts (fresh ephemeral key each time)")
    func freshEphemeralEachSeal() throws {
        let recipient = DHKeyPair()
        let plaintext = Data("same message".utf8)

        let (_, ct1) = try seal(plaintext, recipientPublicKeyData: recipient.publicKeyData)
        let (_, ct2) = try seal(plaintext, recipientPublicKeyData: recipient.publicKeyData)

        #expect(ct1 != ct2, "Each seal must use a fresh ephemeral key, producing unique ciphertext")
    }

    @Test("Ciphertext does not contain the plaintext in clear")
    func ciphertextIsOpaque() throws {
        let recipient = DHKeyPair()
        let plaintext = Data("SophaxChat_visible_marker".utf8)

        let (_, ciphertext) = try seal(plaintext, recipientPublicKeyData: recipient.publicKeyData)

        // The raw marker string must not appear in the ciphertext bytes
        let range = ciphertext.range(of: plaintext)
        #expect(range == nil, "Plaintext must not appear verbatim inside ciphertext")
    }

    @Test("Tampered ciphertext fails authentication")
    func tamperedCiphertextFails() throws {
        let recipient = DHKeyPair()
        let plaintext = Data("hello".utf8)

        let (ephPub, var ciphertext) = try seal(plaintext, recipientPublicKeyData: recipient.publicKeyData)
        // Flip a byte in the middle of the ciphertext (skip 12-byte nonce at start)
        ciphertext[16] ^= 0xFF

        #expect(throws: (any Error).self) {
            _ = try unseal(ephemeralPublicKey: ephPub, encryptedPayload: ciphertext,
                           recipientPrivateKey: recipient.privateKey)
        }
    }
}

// MARK: - Double Ratchet Header Encryption Tests

@Suite("DR Header Encryption")
struct DRHeaderEncryptionTests {

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

    @Test("Encrypted message does not expose message number in clear")
    func messageNumberIsHidden() throws {
        let (alice, _) = try makeSessionPair()
        // Send 5 messages to advance the counter
        var lastMessage: RatchetMessage?
        for i in 0..<5 {
            lastMessage = try alice.encrypt(plaintext: Data("msg\(i)".utf8))
        }
        guard let msg = lastMessage else { return }

        // The byte sequence [0, 0, 0, 4] (message number = 4 in big-endian) must not
        // appear unprotected in the encryptedHeader or ciphertext
        let msgNum4 = Data([0, 0, 0, 4])
        #expect(msg.encryptedHeader.range(of: msgNum4) == nil,
                "Message number must not appear in plain text inside encryptedHeader")
        #expect(msg.ciphertext.range(of: msgNum4) == nil,
                "Message number must not appear in plain text inside ciphertext")
    }

    @Test("Decryption fails when encryptedHeader is tampered")
    func tamperedHeaderFails() throws {
        let (alice, bob) = try makeSessionPair()
        var enc = try alice.encrypt(plaintext: Data("hello".utf8))
        // Corrupt the first byte of the encrypted header
        var hdr = enc.encryptedHeader
        hdr[0] ^= 0xFF
        enc = RatchetMessage(encryptedHeader: hdr, ciphertext: enc.ciphertext)

        #expect(throws: (any Error).self) {
            _ = try bob.decrypt(message: enc)
        }
    }

    @Test("Decryption fails when ciphertext body is tampered but header is intact")
    func tamperedBodyFails() throws {
        let (alice, bob) = try makeSessionPair()
        var enc = try alice.encrypt(plaintext: Data("hello".utf8))
        // Corrupt the last byte of the body (Poly1305 tag is at the end)
        var ct = enc.ciphertext
        ct[ct.count - 1] ^= 0xFF
        enc = RatchetMessage(encryptedHeader: enc.encryptedHeader, ciphertext: ct)

        #expect(throws: (any Error).self) {
            _ = try bob.decrypt(message: enc)
        }
    }

    @Test("Header and body are bound: swapping header between two messages fails")
    func headerBodyBinding() throws {
        let (alice, bob) = try makeSessionPair()
        let enc0 = try alice.encrypt(plaintext: Data("first".utf8))
        let enc1 = try alice.encrypt(plaintext: Data("second".utf8))

        // Mix header from enc1 with body from enc0 — should fail (AAD mismatch)
        let mixed = RatchetMessage(encryptedHeader: enc1.encryptedHeader, ciphertext: enc0.ciphertext)

        #expect(throws: (any Error).self) {
            _ = try bob.decrypt(message: mixed)
        }
    }
}

// MARK: - Group Sender Key Ratchet Tests

@Suite("Group Sender Key Ratchet")
struct GroupSenderKeyRatchetTests {

    /// Standalone HMAC-SHA256 sender key ratchet step (mirrors ChatManager.senderKeyRatchetStep).
    private func ratchetStep(_ chainKey: Data) -> (messageKey: Data, nextChainKey: Data) {
        let ck = SymmetricKey(data: chainKey)
        let mk = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: ck))
        let nk = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: ck))
        return (mk, nk)
    }

    @Test("Message key and next chain key differ from each other and from input")
    func distinctOutputs() {
        let ck0 = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let (mk, nk) = ratchetStep(ck0)
        #expect(mk != nk, "Message key must differ from next chain key")
        #expect(mk != ck0, "Message key must differ from input chain key")
        #expect(nk != ck0, "Next chain key must differ from input chain key")
    }

    @Test("Consecutive iterations produce different message keys (no key reuse)")
    func noKeyReuse() {
        let ck0 = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let (mk0, ck1) = ratchetStep(ck0)
        let (mk1, _)   = ratchetStep(ck1)
        #expect(mk0 != mk1, "Each ratchet step must produce a unique message key")
    }

    @Test("Chain is deterministic: same input always produces same output")
    func deterministic() {
        let ck = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let (mk1, nk1) = ratchetStep(ck)
        let (mk2, nk2) = ratchetStep(ck)
        #expect(mk1 == mk2, "Same chain key must always produce the same message key")
        #expect(nk1 == nk2, "Same chain key must always produce the same next chain key")
    }

    @Test("100-step chain produces 100 distinct message keys")
    func longChain() {
        var ck = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var keys: [Data] = []
        for _ in 0..<100 {
            let (mk, nk) = ratchetStep(ck)
            keys.append(mk)
            ck = nk
        }
        let unique = Set(keys.map { $0.base64EncodedString() })
        #expect(unique.count == 100, "100 ratchet steps must produce 100 unique message keys")
    }

    @Test("SenderKeyState encodes and decodes correctly")
    func senderKeyStateCodable() throws {
        let chainKey  = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let state     = SenderKeyState(chainKey: chainKey, iteration: 42)
        let encoded   = try JSONEncoder().encode(state)
        let decoded   = try JSONDecoder().decode(SenderKeyState.self, from: encoded)
        #expect(decoded.chainKey  == state.chainKey)
        #expect(decoded.iteration == state.iteration)
    }

    @Test("Out-of-order recovery: skipping N steps then receiving in-order is consistent")
    func skipAndRecover() {
        // Simulate sender advancing 5 steps; receiver processes step 4 first, then 0-3
        var ck = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var allKeys: [Data] = []
        var ckCopy = ck
        for _ in 0..<5 {
            let (mk, nk) = ratchetStep(ckCopy)
            allKeys.append(mk)
            ckCopy = nk
        }
        // "Receiver" independently derives step-4 key by advancing from the same initial ck
        var rxCK = ck
        for _ in 0..<4 { let (_, nk) = ratchetStep(rxCK); rxCK = nk }
        let (mk4, _) = ratchetStep(rxCK)
        #expect(mk4 == allKeys[4], "Receiver must derive the same message key for step 4 as the sender")

        // Verify all 5 keys are unique
        let unique = Set(allKeys.map { $0.base64EncodedString() })
        #expect(unique.count == 5, "All 5 message keys must be distinct")
    }
}
