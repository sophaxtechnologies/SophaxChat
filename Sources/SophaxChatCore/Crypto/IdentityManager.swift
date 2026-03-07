// IdentityManager.swift
// SophaxChatCore
//
// Manages the user's cryptographic identity.
//
// Identity = two key pairs:
//   1. Signing key pair (Ed25519) — for identity proofs and prekey signatures
//   2. DH key pair (X25519)       — for X3DH key agreement
//
// Both keys are persisted in the Keychain with kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
// The identity is stable across app launches.

import Foundation
import CryptoKit

public final class IdentityManager: @unchecked Sendable {

    // MARK: - Public Identity (safe to share)

    public struct PublicIdentity: Codable, Equatable {
        /// Display name chosen by the user.
        public let username: String
        /// Ed25519 signing public key (32 bytes).
        public let signingKeyPublic: Data
        /// X25519 DH public key (32 bytes).
        public let dhKeyPublic: Data
        /// Human-readable safety number (fingerprint) for out-of-band verification.
        public let safetyNumber: String

        public var signingKey: Curve25519.Signing.PublicKey? {
            try? Curve25519.Signing.PublicKey(rawRepresentation: signingKeyPublic)
        }

        public var dhKey: Curve25519.KeyAgreement.PublicKey? {
            try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: dhKeyPublic)
        }

        /// A stable, unique peer identifier derived from the identity keys.
        /// Used as the MultipeerConnectivity display name and as Keychain account suffix.
        public var peerID: String {
            let combined = signingKeyPublic + dhKeyPublic
            let hash = SHA256.hash(data: combined)
            return Data(hash).prefix(16).hexString
        }
    }

    // MARK: - Private state

    private let keychain: KeychainManager
    private var signingPair: SigningKeyPair!
    private var dhPair: DHKeyPair!
    public private(set) var publicIdentity: PublicIdentity!

    // MARK: - Init

    public init(keychain: KeychainManager) throws {
        self.keychain = keychain
        try loadOrCreate()
    }

    private func loadOrCreate() throws {
        let signing: Curve25519.Signing.PrivateKey
        let dh: Curve25519.KeyAgreement.PrivateKey

        let signingLoaded = try? keychain.loadSigningKey()
        let dhLoaded      = try? keychain.loadDHIdentityKey()

        if let s = signingLoaded, let d = dhLoaded {
            signing = s
            dh = d
        } else {
            // First launch — generate identity
            signing = Curve25519.Signing.PrivateKey()
            dh      = Curve25519.KeyAgreement.PrivateKey()
            try keychain.saveSigningKey(signing)
            try keychain.saveDHIdentityKey(dh)
        }

        signingPair = SigningKeyPair(privateKey: signing)
        dhPair      = DHKeyPair(privateKey: dh)

        let username = (try? keychain.loadUsername()) ?? "Anonymous"
        publicIdentity = buildPublicIdentity(username: username, signing: signingPair, dh: dhPair)
    }

    // MARK: - Public API

    public func setUsername(_ username: String) throws {
        try keychain.saveUsername(username)
        publicIdentity = buildPublicIdentity(username: username, signing: signingPair, dh: dhPair)
    }

    public var signingKeyPair: SigningKeyPair { signingPair }
    public var dhKeyPair: DHKeyPair { dhPair }

    /// Sign arbitrary data with the identity signing key.
    public func sign(_ data: Data) throws -> Data {
        let sig = try signingPair.privateKey.signature(for: data)
        return sig
    }

    /// Verify a signature made by a given signing public key.
    public static func verify(
        signature: Data,
        for data: Data,
        signingKeyPublic: Data
    ) throws -> Bool {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: signingKeyPublic)
        return key.isValidSignature(signature, for: data)
    }

    // MARK: - Private helpers

    private func buildPublicIdentity(
        username: String,
        signing: SigningKeyPair,
        dh: DHKeyPair
    ) -> PublicIdentity {
        let safetyNumber = generateSafetyNumber(signing: signing.publicKeyData, dh: dh.publicKeyData)
        return PublicIdentity(
            username: username,
            signingKeyPublic: signing.publicKeyData,
            dhKeyPublic: dh.publicKeyData,
            safetyNumber: safetyNumber
        )
    }

    /// Generates a 60-character safety number split into 12 groups of 5 digits.
    /// Used for out-of-band identity verification (read aloud or compare QR codes).
    private func generateSafetyNumber(signing: Data, dh: Data) -> String {
        let combined = signing + dh
        let hash = SHA512.hash(data: combined)
        let hashData = Data(hash)

        // Take first 30 bytes, convert each pair to a decimal number 00000–99999
        var groups: [String] = []
        for i in stride(from: 0, to: 30, by: 5) {
            let chunk = hashData[i..<(i + 5)]
            let value = chunk.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 100_000
            groups.append(String(format: "%05d", value))
        }
        return groups.joined(separator: " ")
    }
}

// MARK: - Data hex helper

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
