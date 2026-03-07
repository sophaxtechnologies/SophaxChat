// DoubleRatchet.swift
// SophaxChatCore
//
// Double Ratchet Algorithm — provides:
//   • Forward secrecy:    compromise of current key doesn't expose past messages
//   • Break-in recovery:  after compromise, future messages become secure again
//
// The Double Ratchet combines:
//   1. DH Ratchet      — generates new DH secrets on each exchange (break-in recovery)
//   2. Symmetric Ratchet — HMAC chain advancing with each message (forward secrecy)
//
// Encryption: ChaCha20-Poly1305 (AEAD)
//   • The message header is authenticated but NOT encrypted (AAD)
//   • This reveals the ratchet public key, message number, and chain length
//   • For metadata protection, header encryption can be added (future work)
//
// Reference: https://signal.org/docs/specifications/doubleratchet/

import Foundation
import CryptoKit

// MARK: - Message structures

/// Header included with every message (authenticated, not encrypted).
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
    /// Authenticated (but not encrypted) header.
    public let header: RatchetHeader
    /// ChaCha20-Poly1305 sealed box: nonce (12B) + ciphertext + tag (16B).
    public let ciphertext: Data
}

// MARK: - Skipped message key identifier

struct SkippedKeyID: Hashable, Codable {
    let ratchetKeyData: Data
    let messageNumber:  UInt32
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
    var sendMessageCount:              UInt32 = 0
    var receiveMessageCount:           UInt32 = 0
    var previousSendingChainLength:    UInt32 = 0

    // Skipped message keys (bounded by CryptoConstants.maxSkippedMessages)
    var skippedMessageKeys: [SkippedKeyID: SerializableSymmetricKey] = [:]
}

// MARK: - Double Ratchet

public final class DoubleRatchet: @unchecked Sendable {

    private var state: RatchetSessionState

    // MARK: - Initialization

    /// Initialize as the **initiating party (Alice)**.
    /// Called after X3DH with the shared secret and Bob's initial ratchet public key (SPK_B).
    public static func initAsInitiator(
        sharedSecret: SymmetricKey,
        remoteRatchetPublicKey: Data        // Bob's SPK public key
    ) throws -> DoubleRatchet {
        let sendingPair = DHKeyPair()
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteRatchetPublicKey)

        // Perform initial DH ratchet step to derive sending chain key
        let dhOut = try sendingPair.privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let (newRootKey, sendingChainKey) = kdfRK(rootKey: sharedSecret, dhOutput: dhOut)

        let state = RatchetSessionState(
            sendingRatchetPrivateKey:  sendingPair.privateKey.rawRepresentation,
            sendingRatchetPublicKey:   sendingPair.publicKeyData,
            receivingRatchetPublicKey: remoteRatchetPublicKey,
            rootKey:                   SerializableSymmetricKey(newRootKey),
            sendingChainKey:           SerializableSymmetricKey(sendingChainKey),
            receivingChainKey:         nil
        )
        return DoubleRatchet(state: state)
    }

    /// Initialize as the **receiving party (Bob)**.
    /// Called after X3DH with the shared secret.
    /// Bob's sending chain is not available until he receives Alice's first message.
    public static func initAsResponder(
        sharedSecret: SymmetricKey,
        ownRatchetKeyPair: DHKeyPair    // Bob's SPK, which becomes his initial ratchet key
    ) throws -> DoubleRatchet {
        let state = RatchetSessionState(
            sendingRatchetPrivateKey:  ownRatchetKeyPair.privateKey.rawRepresentation,
            sendingRatchetPublicKey:   ownRatchetKeyPair.publicKeyData,
            receivingRatchetPublicKey: nil,
            rootKey:                   SerializableSymmetricKey(sharedSecret),
            sendingChainKey:           nil,
            receivingChainKey:         nil
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
    ///   - associatedData: Additional data to authenticate (e.g. conversation ID, sender/receiver IDs)
    /// - Returns: Encrypted `RatchetMessage` ready to send
    public func encrypt(plaintext: Data, associatedData: Data = Data()) throws -> RatchetMessage {
        guard let ck = state.sendingChainKey?.key else {
            throw SophaxError.missingChainKey
        }

        // Advance the sending chain
        let (newCK, mk) = Self.kdfCK(ck)
        state.sendingChainKey = SerializableSymmetricKey(newCK)

        let header = RatchetHeader(
            senderRatchetKey:     state.sendingRatchetPublicKey,
            previousChainLength:  state.previousSendingChainLength,
            messageNumber:        state.sendMessageCount
        )
        state.sendMessageCount += 1

        let ciphertext = try encryptWithKey(mk, plaintext: plaintext, header: header, associatedData: associatedData)
        return RatchetMessage(header: header, ciphertext: ciphertext)
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

        // 2. Perform DH ratchet step if the sender's ratchet key changed
        if message.header.senderRatchetKey != state.receivingRatchetPublicKey {
            try skipMessageKeys(until: message.header.previousChainLength)
            try dhRatchetStep(with: message.header.senderRatchetKey)
        }

        // 3. Skip to the message's position in the current chain
        try skipMessageKeys(until: message.header.messageNumber)

        // 4. Decrypt with the current receiving chain key
        guard let ck = state.receivingChainKey?.key else {
            throw SophaxError.missingChainKey
        }
        let (newCK, mk) = Self.kdfCK(ck)
        state.receivingChainKey = SerializableSymmetricKey(newCK)
        state.receiveMessageCount += 1

        return try decryptWithKey(mk, message: message, associatedData: associatedData)
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

    /// Advance the DH ratchet: derive new root key, receiving chain key, then new sending chain key.
    private func dhRatchetStep(with remoteRatchetPublicKeyData: Data) throws {
        state.previousSendingChainLength = state.sendMessageCount
        state.sendMessageCount           = 0
        state.receiveMessageCount        = 0
        state.receivingRatchetPublicKey  = remoteRatchetPublicKeyData

        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteRatchetPublicKeyData)
        let currentSendingKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: state.sendingRatchetPrivateKey
        )

        // Step 1: DH(current_sending, new_remote) → receiving chain key
        let dhOut1 = try currentSendingKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let (rk1, receivingCK) = Self.kdfRK(rootKey: state.rootKey.key, dhOutput: dhOut1)
        state.rootKey          = SerializableSymmetricKey(rk1)
        state.receivingChainKey = SerializableSymmetricKey(receivingCK)

        // Step 2: Generate new sending ratchet key pair
        let newSendingPair = DHKeyPair()
        state.sendingRatchetPrivateKey = newSendingPair.privateKey.rawRepresentation
        state.sendingRatchetPublicKey  = newSendingPair.publicKeyData

        // Step 3: DH(new_sending, new_remote) → sending chain key
        let dhOut2 = try newSendingPair.privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let (rk2, sendingCK) = Self.kdfRK(rootKey: rk1, dhOutput: dhOut2)
        state.rootKey        = SerializableSymmetricKey(rk2)
        state.sendingChainKey = SerializableSymmetricKey(sendingCK)
    }

    // MARK: - Private: Skip message keys

    /// Compute and store message keys for messages N through `target - 1`.
    /// These are cached so out-of-order messages can still be decrypted.
    private func skipMessageKeys(until target: UInt32) throws {
        guard let ck = state.receivingChainKey?.key else { return }   // No chain yet

        let totalSkipped = Int(target) - Int(state.receiveMessageCount)
        guard totalSkipped >= 0 else { return }
        guard state.skippedMessageKeys.count + totalSkipped <= CryptoConstants.maxSkippedMessages else {
            throw SophaxError.tooManySkippedMessages
        }

        var chainKey = ck
        let ratchetKeyData = state.receivingRatchetPublicKey ?? Data()

        while state.receiveMessageCount < target {
            let (newCK, mk) = Self.kdfCK(chainKey)
            let keyID = SkippedKeyID(
                ratchetKeyData: ratchetKeyData,
                messageNumber:  state.receiveMessageCount
            )
            state.skippedMessageKeys[keyID] = SerializableSymmetricKey(mk)
            chainKey = newCK
            state.receiveMessageCount += 1
        }
        state.receivingChainKey = SerializableSymmetricKey(chainKey)
    }

    // MARK: - Private: Try skipped key decryption

    private func decryptWithSkippedKey(message: RatchetMessage, associatedData: Data) throws -> Data? {
        let keyID = SkippedKeyID(
            ratchetKeyData: message.header.senderRatchetKey,
            messageNumber:  message.header.messageNumber
        )
        guard let skippedMK = state.skippedMessageKeys[keyID]?.key else {
            return nil
        }
        state.skippedMessageKeys.removeValue(forKey: keyID)
        return try decryptWithKey(skippedMK, message: message, associatedData: associatedData)
    }

    // MARK: - Private: Low-level encrypt/decrypt

    private func encryptWithKey(
        _ mk: MessageKey,
        plaintext: Data,
        header: RatchetHeader,
        associatedData: Data
    ) throws -> Data {
        let headerData = try JSONEncoder().encode(header)
        let aad = associatedData + headerData                // AAD = session_AD || header

        let nonce  = ChaChaPoly.Nonce()                     // Random 96-bit nonce
        let sealed = try ChaChaPoly.seal(plaintext, using: mk, nonce: nonce, authenticating: aad)
        return sealed.combined                              // nonce (12B) + ciphertext + tag (16B)
    }

    private func decryptWithKey(
        _ mk: MessageKey,
        message: RatchetMessage,
        associatedData: Data
    ) throws -> Data {
        let headerData = try JSONEncoder().encode(message.header)
        let aad = associatedData + headerData

        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: message.ciphertext)
            return try ChaChaPoly.open(sealedBox, using: mk, authenticating: aad)
        } catch {
            throw SophaxError.decryptionFailed
        }
    }

    // MARK: - KDF Functions

    /// KDF_RK(rk, dh_out) → (new_root_key, chain_key)
    /// HKDF-SHA256: salt = rk, IKM = dh_out, info = app-specific, output = 64 bytes
    static func kdfRK(rootKey: SymmetricKey, dhOutput: SharedSecret) -> (RootKey, ChainKey) {
        let saltData = rootKey.withUnsafeBytes { Data($0) }

        var ikmData = Data()
        dhOutput.withUnsafeBytes { ikmData.append(contentsOf: $0) }

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikmData),
            salt: saltData,
            info: CryptoConstants.rkInfo,
            outputByteCount: 64
        )

        let derivedBytes = derived.withUnsafeBytes { Data($0) }
        return (
            SymmetricKey(data: derivedBytes.prefix(32)),   // new root key
            SymmetricKey(data: derivedBytes.suffix(32))    // new chain key
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
}
