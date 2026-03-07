// X3DH.swift
// SophaxChatCore
//
// Extended Triple Diffie-Hellman (X3DH) key agreement protocol.
// Establishes a shared secret between two parties asynchronously —
// the initiating party (Alice) can compute the secret even before
// the responding party (Bob) is online.
//
// The shared secret seeds the Double Ratchet.
//
// Reference: https://signal.org/docs/specifications/x3dh/
//
// DH operations:
//   DH1 = DH(IK_A, SPK_B)  — identity auth
//   DH2 = DH(EK_A, IK_B)   — ephemeral x identity
//   DH3 = DH(EK_A, SPK_B)  — ephemeral x signed prekey
//   DH4 = DH(EK_A, OPK_B)  — ephemeral x one-time prekey (if available)
//   SK  = KDF(DH1 || DH2 || DH3 [|| DH4])

import Foundation
import CryptoKit

public enum X3DH {

    // MARK: - Sender (Alice)

    public struct SenderResult {
        /// The derived shared secret to seed the Double Ratchet.
        public let sharedSecret: SymmetricKey
        /// Alice's ephemeral public key — sent to Bob in the InitialMessage.
        public let ephemeralPublicKey: Data
        /// Which of Bob's one-time prekeys was used (if any) — sent to Bob.
        public let usedOneTimePreKeyId: UInt32?
    }

    /// Perform X3DH as the initiating party (Alice).
    ///
    /// - Parameters:
    ///   - senderIdentity: Alice's DH identity key pair (IK_A)
    ///   - recipientBundle: Bob's published prekey bundle
    /// - Returns: Shared secret + ephemeral key info to send Bob
    public static func initiateSender(
        senderIdentity: DHKeyPair,
        recipientBundle: PreKeyBundle
    ) throws -> SenderResult {

        // 1. Validate bundle timestamp
        guard abs(recipientBundle.timestamp.timeIntervalSinceNow) < CryptoConstants.maxPreKeyBundleAge else {
            throw SophaxError.stalePreKeyBundle
        }

        // 2. Verify signed prekey signature
        guard try recipientBundle.verifySignedPreKey() else {
            throw SophaxError.invalidSignature
        }

        // 3. Decode recipient keys
        let recipientIK  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientBundle.dhIdentityKeyPublic)
        let recipientSPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientBundle.signedPreKeyPublic)

        // 4. Generate Alice's ephemeral key pair
        let ephemeralPair = DHKeyPair()

        // 5. DH computations
        // DH1 = DH(IK_A, SPK_B)
        let dh1 = try senderIdentity.privateKey.sharedSecretFromKeyAgreement(with: recipientSPK)
        // DH2 = DH(EK_A, IK_B)
        let dh2 = try ephemeralPair.privateKey.sharedSecretFromKeyAgreement(with: recipientIK)
        // DH3 = DH(EK_A, SPK_B)
        let dh3 = try ephemeralPair.privateKey.sharedSecretFromKeyAgreement(with: recipientSPK)

        var dhConcat = Data()
        dh1.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        dh2.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        dh3.withUnsafeBytes { dhConcat.append(contentsOf: $0) }

        var usedOTPKId: UInt32? = nil
        if let otpkData = recipientBundle.oneTimePreKeyPublic,
           let otpkId   = recipientBundle.oneTimePreKeyId {
            // DH4 = DH(EK_A, OPK_B)
            let recipientOPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: otpkData)
            let dh4 = try ephemeralPair.privateKey.sharedSecretFromKeyAgreement(with: recipientOPK)
            dh4.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
            usedOTPKId = otpkId
        }

        // 6. Derive shared secret via HKDF
        let sharedSecret = deriveSharedSecret(from: dhConcat)

        return SenderResult(
            sharedSecret: sharedSecret,
            ephemeralPublicKey: ephemeralPair.publicKeyData,
            usedOneTimePreKeyId: usedOTPKId
        )
    }

    // MARK: - Receiver (Bob)

    /// Perform X3DH as the receiving party (Bob).
    ///
    /// - Parameters:
    ///   - recipientIdentityDH: Bob's DH identity key pair (IK_B)
    ///   - recipientSignedPreKey: Bob's signed prekey pair (SPK_B) — used in X3DH
    ///   - recipientOneTimePreKey: Bob's one-time prekey pair (OPK_B) — if Alice used one
    ///   - senderIdentityDHKeyData: Alice's DH identity public key (IK_A)
    ///   - senderEphemeralKeyData: Alice's ephemeral public key (EK_A) from the message
    /// - Returns: Shared secret (must match Alice's)
    public static func initiateReceiver(
        recipientIdentityDH: DHKeyPair,
        recipientSignedPreKey: DHKeyPair,
        recipientOneTimePreKey: DHKeyPair?,
        senderIdentityDHKeyData: Data,
        senderEphemeralKeyData: Data
    ) throws -> SymmetricKey {

        let senderIK  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderIdentityDHKeyData)
        let senderEK  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderEphemeralKeyData)

        // DH1 = DH(SPK_B, IK_A)   [symmetric to Alice's DH1]
        let dh1 = try recipientSignedPreKey.privateKey.sharedSecretFromKeyAgreement(with: senderIK)
        // DH2 = DH(IK_B, EK_A)
        let dh2 = try recipientIdentityDH.privateKey.sharedSecretFromKeyAgreement(with: senderEK)
        // DH3 = DH(SPK_B, EK_A)
        let dh3 = try recipientSignedPreKey.privateKey.sharedSecretFromKeyAgreement(with: senderEK)

        var dhConcat = Data()
        dh1.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        dh2.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        dh3.withUnsafeBytes { dhConcat.append(contentsOf: $0) }

        if let otp = recipientOneTimePreKey {
            // DH4 = DH(OPK_B, EK_A)
            let dh4 = try otp.privateKey.sharedSecretFromKeyAgreement(with: senderEK)
            dh4.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        }

        return deriveSharedSecret(from: dhConcat)
    }

    // MARK: - KDF

    /// HKDF-SHA256 key derivation.
    /// Follows the Signal X3DH spec: F || DH_concat is the IKM,
    /// where F = 32 bytes of 0xFF (domain separator for non-empty use).
    private static func deriveSharedSecret(from dhConcat: Data) -> SymmetricKey {
        // Per Signal X3DH spec: prepend 32 0xFF bytes as domain separator
        let f   = Data(repeating: 0xFF, count: 32)
        let ikm = f + dhConcat
        let salt = Data(repeating: 0x00, count: 32)   // 32 zero bytes as salt

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: CryptoConstants.x3dhInfo,
            outputByteCount: 32
        )
    }
}
