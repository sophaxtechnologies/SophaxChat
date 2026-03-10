// DoubleRatchet.swift
// SophaxChatCore
//
// Double Ratchet with Header Encryption (HE).
//
// Provides:
//   • Forward secrecy:    compromise of current key doesn't expose past messages
//   • Break-in recovery:  after compromise, future messages become secure again
//   • Header privacy:     ratchet public key, message number, and chain length are
//                         encrypted — relay nodes see only opaque ciphertext
//
// The Double Ratchet combines:
//   1. DH Ratchet      — generates new DH secrets on each exchange (break-in recovery)
//   2. Symmetric Ratchet — HMAC chain advancing with each message (forward secrecy)
//   3. Header Encryption — header encrypted with a rotating header key (privacy)
//
// Encryption: ChaCha20-Poly1305 (AEAD), both for header and body.
// The encrypted header is used as AAD for the body AEAD, binding them together.
//
// Reference: https://signal.org/docs/specifications/doubleratchet/ §4.3

import Foundation
import CryptoKit

// MARK: - Message structures

/// Header included with every Double Ratchet message.
/// Serialised to JSON, then encrypted with the sending header key before transmission.
public struct RatchetHeader: Codable, Equatable, Sendable {
    /// Sender's current DH ratchet public key.
    public let senderRatchetKey: Data
    /// Number of messages sent in the PREVIOUS sending chain (PN).
    public let previousChainLength: UInt32
    /// Message number in the CURRENT sending chain (N).
    public let messageNumber: UInt32
}

/// A complete encrypted Double Ratchet message.
public struct RatchetMessage: Codable, Sendable {
    /// Encrypted header: ChaCha20-Poly1305(nonce‖ciphertext‖tag).
    /// Also used as AAD for the body AEAD, preventing header/body swapping.
    public let encryptedHeader: Data
    /// ChaCha20-Poly1305 sealed box: nonce(12B) + ciphertext + tag(16B).
    public let ciphertext: Data
}

// MARK: - Session State (Codable for Keychain persistence)

struct RatchetSessionState: Codable {
    // DH ratchet sending key pair
    var sendingRatchetPrivateKey: Data
    var sendingRatchetPublicKey:  Data

    // DH ratchet receiving public key (nil until first message received)
    var receivingRatchetPublicKey: Data?

    // Root key
    var rootKey: SerializableSymmetricKey

    // Chain keys (nil until the corresponding ratchet step happens)
    var sendingChainKey:   SerializableSymmetricKey?
    var receivingChainKey: SerializableSymmetricKey?

    // Message counters
    var sendMessageCount:           UInt32 = 0
    var receiveMessageCount:        UInt32 = 0
    var previousSendingChainLength: UInt32 = 0

    // Header encryption keys
    var sendingHeaderKey:       SerializableSymmetricKey?   // HKs
    var receivingHeaderKey:     SerializableSymmetricKey?   // HKr
    var nextSendingHeaderKey:   SerializableSymmetricKey?   // NHKs
    var nextReceivingHeaderKey: SerializableSymmetricKey?   // NHKr

    // Skipped message keys indexed by base64(headerKey) → msgNumStr → messageKey.
    // Bounded by CryptoConstants.maxSkippedMessages across all bundles.
    var skippedKeyBundles: [String: [String: SerializableSymmetricKey]] = [:]
}

// MARK: - Double Ratchet

public final class DoubleRatchet: @unchecked Sendable {

    private var state: RatchetSessionState

    // MARK: - Initialization

    /// Initialize as the **initiating party (Alice)**.
    /// Called after X3DH with the shared secret and Bob's initial ratchet public key (SPK_B).
    ///
    /// Header key setup (derived from SK before the DH ratchet step):
    ///   HKs  = HKDF(SK, hkAliceInfo)  — Alice's first sending header key
    ///   NHKr = HKDF(SK, nhkBobInfo)   — Alice's initial NHKr (= Bob's NHKs)
    ///   NHKs comes from the initial kdfRK output (DH ratchet step Alice performs immediately)
    public static func initAsInitiator(
        sharedSecret: SymmetricKey,
        remoteRatchetPublicKey: Data        // Bob's SPK public key
    ) throws -> DoubleRatchet {
        let sendingPair = DHKeyPair()
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteRatchetPublicKey)

        // Derive initial header keys from X3DH shared secret
        let hks  = deriveHeaderKey(from: sharedSecret, info: CryptoConstants.hkAliceInfo)
        let nhkr = deriveHeaderKey(from: sharedSecret, info: CryptoConstants.nhkBobInfo)

        // Perform initial DH ratchet step — produces sending chain key and NHKs
        let dhOut = try sendingPair.privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let (newRootKey, sendingChainKey, nhks) = kdfRK(rootKey: sharedSecret, dhOutput: dhOut)

        let state = RatchetSessionState(
            sendingRatchetPrivateKey:  sendingPair.privateKey.rawRepresentation,
            sendingRatchetPublicKey:   sendingPair.publicKeyData,
            receivingRatchetPublicKey: remoteRatchetPublicKey,
            rootKey:                   SerializableSymmetricKey(newRootKey),
            sendingChainKey:           SerializableSymmetricKey(sendingChainKey),
            receivingChainKey:         nil,
            sendingHeaderKey:          SerializableSymmetricKey(hks),
            receivingHeaderKey:        nil,
            nextSendingHeaderKey:      SerializableSymmetricKey(nhks),
            nextReceivingHeaderKey:    SerializableSymmetricKey(nhkr)
        )
        return DoubleRatchet(state: state)
    }

    /// Initialize as the **receiving party (Bob)**.
    /// Called after X3DH with the shared secret.
    ///
    /// Header key setup:
    ///   NHKr = HKDF(SK, hkAliceInfo)  — Alice's HKs triggers Bob's first DHRatchet
    ///   NHKs = HKDF(SK, nhkBobInfo)   — Bob's first sending header key (after DHRatchet)
    ///   HKs and HKr start nil; Alice's first message arrives via NHKr path → DHRatchet
    public static func initAsResponder(
        sharedSecret: SymmetricKey,
        ownRatchetKeyPair: DHKeyPair    // Bob's SPK, which becomes his initial ratchet key
    ) throws -> DoubleRatchet {
        let nhkr = deriveHeaderKey(from: sharedSecret, info: CryptoConstants.hkAliceInfo)
        let nhks = deriveHeaderKey(from: sharedSecret, info: CryptoConstants.nhkBobInfo)

        let state = RatchetSessionState(
            sendingRatchetPrivateKey:  ownRatchetKeyPair.privateKey.rawRepresentation,
            sendingRatchetPublicKey:   ownRatchetKeyPair.publicKeyData,
            receivingRatchetPublicKey: nil,
            rootKey:                   SerializableSymmetricKey(sharedSecret),
            sendingChainKey:           nil,
            receivingChainKey:         nil,
            sendingHeaderKey:          nil,
            receivingHeaderKey:        nil,
            nextSendingHeaderKey:      SerializableSymmetricKey(nhks),
            nextReceivingHeaderKey:    SerializableSymmetricKey(nhkr)
        )
        return DoubleRatchet(state: state)
    }

    private init(state: RatchetSessionState) {
        self.state = state
    }

    // MARK: - Encrypt

    /// Encrypt a plaintext message.
    /// - Parameters:
    ///   - plaintext: Raw message bytes
    ///   - associatedData: Additional data to authenticate (e.g. sorted peer IDs)
    /// - Returns: Encrypted `RatchetMessage` ready to send
    public func encrypt(plaintext: Data, associatedData: Data = Data()) throws -> RatchetMessage {
        guard let ck = state.sendingChainKey?.key else {
            throw SophaxError.missingChainKey
        }
        guard let hks = state.sendingHeaderKey?.key else {
            throw SophaxError.missingChainKey
        }

        // Advance the sending chain
        let (newCK, mk) = Self.kdfCK(ck)
        state.sendingChainKey = SerializableSymmetricKey(newCK)

        let header = RatchetHeader(
            senderRatchetKey:    state.sendingRatchetPublicKey,
            previousChainLength: state.previousSendingChainLength,
            messageNumber:       state.sendMessageCount
        )
        state.sendMessageCount += 1

        let encryptedHeader = try encryptHeader(header, using: hks)
        let ciphertext = try encryptBody(mk, plaintext: plaintext,
                                        encryptedHeader: encryptedHeader,
                                        associatedData: associatedData)
        return RatchetMessage(encryptedHeader: encryptedHeader, ciphertext: ciphertext)
    }

    // MARK: - Decrypt

    /// Decrypt an incoming `RatchetMessage`.
    /// - Parameters:
    ///   - message: The received encrypted message
    ///   - associatedData: Must match what the sender used in `encrypt`
    /// - Returns: Decrypted plaintext
    public func decrypt(message: RatchetMessage, associatedData: Data = Data()) throws -> Data {

        // 1. Check skipped message keys first (handles out-of-order delivery)
        if let plaintext = try decryptWithSkippedKey(message: message, associatedData: associatedData) {
            return plaintext
        }

        // 2. Try decrypting the header with the current receiving header key (same DH epoch)
        if let hkr = state.receivingHeaderKey?.key,
           let header = try? decryptHeaderBytes(message.encryptedHeader, using: hkr) {
            try skipMessageKeys(until: header.messageNumber)
            guard let ck = state.receivingChainKey?.key else { throw SophaxError.missingChainKey }
            let (newCK, mk) = Self.kdfCK(ck)
            state.receivingChainKey = SerializableSymmetricKey(newCK)
            state.receiveMessageCount += 1
            return try decryptBody(mk, message: message, associatedData: associatedData)
        }

        // 3. Try the next receiving header key (new DH epoch — performs DHRatchet first)
        guard let nhkr = state.nextReceivingHeaderKey?.key,
              let header = try? decryptHeaderBytes(message.encryptedHeader, using: nhkr) else {
            throw SophaxError.decryptionFailed
        }

        // Skip remaining messages in the previous chain before ratcheting
        try skipMessageKeys(until: header.previousChainLength)
        try dhRatchetStep(with: header.senderRatchetKey)
        try skipMessageKeys(until: header.messageNumber)

        guard let ck = state.receivingChainKey?.key else { throw SophaxError.missingChainKey }
        let (newCK, mk) = Self.kdfCK(ck)
        state.receivingChainKey = SerializableSymmetricKey(newCK)
        state.receiveMessageCount += 1
        return try decryptBody(mk, message: message, associatedData: associatedData)
    }

    // MARK: - State Persistence

    public func exportState() throws -> Data {
        try JSONEncoder().encode(state)
    }

    public static func importState(_ data: Data) throws -> DoubleRatchet {
        let state = try JSONDecoder().decode(RatchetSessionState.self, from: data)
        return DoubleRatchet(state: state)
    }

    // MARK: - Private: DH Ratchet Step

    /// Advance the DH ratchet: rotate header keys, derive new receiving chain,
    /// generate new sending key pair, derive new sending chain.
    private func dhRatchetStep(with remoteRatchetPublicKeyData: Data) throws {
        state.previousSendingChainLength = state.sendMessageCount
        state.sendMessageCount           = 0
        state.receiveMessageCount        = 0

        // Rotate header keys (NHK → HK)
        state.sendingHeaderKey   = state.nextSendingHeaderKey
        state.receivingHeaderKey = state.nextReceivingHeaderKey

        state.receivingRatchetPublicKey = remoteRatchetPublicKeyData
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteRatchetPublicKeyData)
        let currentSendingKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: state.sendingRatchetPrivateKey
        )

        // Step 1: DH(current_sending, new_remote) → receiving chain key + NHKr
        let dhOut1 = try currentSendingKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let (rk1, receivingCK, newNHKr) = Self.kdfRK(rootKey: state.rootKey.key, dhOutput: dhOut1)
        state.rootKey                = SerializableSymmetricKey(rk1)
        state.receivingChainKey      = SerializableSymmetricKey(receivingCK)
        state.nextReceivingHeaderKey = SerializableSymmetricKey(newNHKr)

        // Step 2: Generate new sending ratchet key pair
        let newSendingPair = DHKeyPair()
        state.sendingRatchetPrivateKey = newSendingPair.privateKey.rawRepresentation
        state.sendingRatchetPublicKey  = newSendingPair.publicKeyData

        // Step 3: DH(new_sending, new_remote) → sending chain key + NHKs
        let dhOut2 = try newSendingPair.privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let (rk2, sendingCK, newNHKs) = Self.kdfRK(rootKey: rk1, dhOutput: dhOut2)
        state.rootKey              = SerializableSymmetricKey(rk2)
        state.sendingChainKey      = SerializableSymmetricKey(sendingCK)
        state.nextSendingHeaderKey = SerializableSymmetricKey(newNHKs)
    }

    // MARK: - Private: Skip message keys

    /// Compute and store message keys for messages Nr through `target - 1`.
    /// Keyed by base64(HKr) so out-of-order messages can still be decrypted
    /// even after the header key rotates.
    private func skipMessageKeys(until target: UInt32) throws {
        guard let ck = state.receivingChainKey?.key else { return }

        let totalSkipped = Int(target) - Int(state.receiveMessageCount)
        guard totalSkipped >= 0 else { return }

        let totalStored = state.skippedKeyBundles.values.reduce(0) { $0 + $1.count }
        guard totalStored + totalSkipped <= CryptoConstants.maxSkippedMessages else {
            throw SophaxError.tooManySkippedMessages
        }

        // Index skipped keys by the current receiving header key
        let hkrB64 = state.receivingHeaderKey.map {
            $0.key.withUnsafeBytes { Data($0) }.base64EncodedString()
        } ?? ""

        var chainKey = ck
        while state.receiveMessageCount < target {
            let (newCK, mk) = Self.kdfCK(chainKey)
            let msgNumStr = "\(state.receiveMessageCount)"
            state.skippedKeyBundles[hkrB64, default: [:]][msgNumStr] = SerializableSymmetricKey(mk)
            chainKey = newCK
            state.receiveMessageCount += 1
        }
        state.receivingChainKey = SerializableSymmetricKey(chainKey)
    }

    // MARK: - Private: Try skipped key decryption

    private func decryptWithSkippedKey(message: RatchetMessage, associatedData: Data) throws -> Data? {
        for (headerKeyB64, bundle) in state.skippedKeyBundles {
            guard let headerKeyData = Data(base64Encoded: headerKeyB64) else { continue }
            let headerKey = SymmetricKey(data: headerKeyData)
            guard let header = try? decryptHeaderBytes(message.encryptedHeader, using: headerKey) else {
                continue
            }
            let msgNumStr = "\(header.messageNumber)"
            guard let skippedMK = bundle[msgNumStr]?.key else { continue }

            var updatedBundle = bundle
            updatedBundle.removeValue(forKey: msgNumStr)
            if updatedBundle.isEmpty {
                state.skippedKeyBundles.removeValue(forKey: headerKeyB64)
            } else {
                state.skippedKeyBundles[headerKeyB64] = updatedBundle
            }
            return try decryptBody(skippedMK, message: message, associatedData: associatedData)
        }
        return nil
    }

    // MARK: - Private: Header encryption/decryption

    private func encryptHeader(_ header: RatchetHeader, using key: HeaderKey) throws -> Data {
        let headerData = try JSONEncoder().encode(header)
        let nonce      = ChaChaPoly.Nonce()
        let sealed     = try ChaChaPoly.seal(headerData, using: key, nonce: nonce, authenticating: Data())
        return sealed.combined
    }

    private func decryptHeaderBytes(_ encryptedHeader: Data, using key: HeaderKey) throws -> RatchetHeader {
        do {
            let sealedBox  = try ChaChaPoly.SealedBox(combined: encryptedHeader)
            let headerData = try ChaChaPoly.open(sealedBox, using: key, authenticating: Data())
            return try JSONDecoder().decode(RatchetHeader.self, from: headerData)
        } catch {
            throw SophaxError.decryptionFailed
        }
    }

    // MARK: - Private: Body encryption/decryption

    private func encryptBody(
        _ mk: MessageKey,
        plaintext: Data,
        encryptedHeader: Data,
        associatedData: Data
    ) throws -> Data {
        let aad    = associatedData + encryptedHeader   // binds header to body
        let nonce  = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: mk, nonce: nonce, authenticating: aad)
        return sealed.combined
    }

    private func decryptBody(
        _ mk: MessageKey,
        message: RatchetMessage,
        associatedData: Data
    ) throws -> Data {
        let aad = associatedData + message.encryptedHeader
        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: message.ciphertext)
            return try ChaChaPoly.open(sealedBox, using: mk, authenticating: aad)
        } catch {
            throw SophaxError.decryptionFailed
        }
    }

    // MARK: - KDF Functions

    /// KDF_RK(rk, dh_out) → (new_root_key, chain_key, next_header_key)
    /// HKDF-SHA256: salt=rk, IKM=dh_out, info=rkInfo, output=96 bytes (32+32+32)
    static func kdfRK(rootKey: SymmetricKey, dhOutput: SharedSecret) -> (RootKey, ChainKey, HeaderKey) {
        let saltData = rootKey.withUnsafeBytes { Data($0) }

        var ikmData = Data()
        dhOutput.withUnsafeBytes { ikmData.append(contentsOf: $0) }

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikmData),
            salt: saltData,
            info: CryptoConstants.rkInfo,
            outputByteCount: 96
        )

        let derivedBytes = derived.withUnsafeBytes { Data($0) }
        return (
            SymmetricKey(data: derivedBytes[0..<32]),    // new root key
            SymmetricKey(data: derivedBytes[32..<64]),   // new chain key
            SymmetricKey(data: derivedBytes[64..<96])    // next header key
        )
    }

    /// KDF_CK(ck) → (new_chain_key, message_key)
    /// HMAC-SHA256(ck, 0x02) = next chain key
    /// HMAC-SHA256(ck, 0x01) = message key
    static func kdfCK(_ chainKey: ChainKey) -> (ChainKey, MessageKey) {
        let newCKBytes = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: chainKey))
        let mkBytes    = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: chainKey))
        return (SymmetricKey(data: newCKBytes), SymmetricKey(data: mkBytes))
    }

    /// Derive a header key from the X3DH shared secret using a distinct info string.
    private static func deriveHeaderKey(from sharedSecret: SymmetricKey, info: Data) -> HeaderKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            info: info,
            outputByteCount: 32
        )
    }
}
