// CryptoTypes.swift
// SophaxChatCore
//
// Core cryptographic type definitions and constants.
// All crypto operations use Apple's CryptoKit framework:
//   - Curve25519 for key agreement (X25519) and signing (Ed25519)
//   - ChaChaPoly (ChaCha20-Poly1305) for AEAD encryption
//   - HKDF-SHA256 for key derivation
//   - HMAC-SHA256 for chain key ratcheting

import Foundation
import CryptoKit

// MARK: - Type Aliases

public typealias RootKey = SymmetricKey
public typealias ChainKey = SymmetricKey
public typealias MessageKey = SymmetricKey
public typealias HeaderKey = SymmetricKey

// MARK: - DH Key Pair (X25519)

/// Wrapper around Curve25519 key agreement key pair (X25519).
/// Used for: identity DH, signed prekeys, one-time prekeys, ratchet keys.
public struct DHKeyPair {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
    }

    public var publicKey: Curve25519.KeyAgreement.PublicKey {
        privateKey.publicKey
    }

    public var publicKeyData: Data {
        publicKey.rawRepresentation
    }
}

// MARK: - Signing Key Pair (Ed25519)

/// Wrapper around Curve25519 signing key pair (Ed25519).
/// Used for: identity signing key, signed prekey signatures.
public struct SigningKeyPair {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init() {
        self.privateKey = Curve25519.Signing.PrivateKey()
    }

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public var publicKey: Curve25519.Signing.PublicKey {
        privateKey.publicKey
    }

    public var publicKeyData: Data {
        publicKey.rawRepresentation
    }
}

// MARK: - Serializable Symmetric Key

/// Codable wrapper for SymmetricKey.
/// SymmetricKey doesn't conform to Codable — this bridges the gap.
/// The raw key bytes are stored and must be protected by the caller.
public struct SerializableSymmetricKey: Codable, Equatable {
    private let rawData: Data

    public init(_ key: SymmetricKey) {
        self.rawData = key.withUnsafeBytes { Data($0) }
    }

    public var key: SymmetricKey {
        SymmetricKey(data: rawData)
    }
}

// MARK: - Constants

public enum CryptoConstants {
    /// App identifier included in all KDF info strings to domain-separate keys.
    public static let appVersion = "SophaxChat_v1"

    // KDF info strings (domain separation)
    public static let rkInfo       = Data("SophaxChat_RootKey_v1".utf8)
    public static let x3dhInfo     = Data("SophaxChat_X3DH_v1".utf8)
    public static let storageInfo  = Data("SophaxChat_Storage_v1".utf8)
    public static let sessionInfo  = Data("SophaxChat_Session_v1".utf8)

    // Sealed sender KDF info string
    public static let sealedSenderInfo = Data("SophaxChat_SealedSender_v1".utf8)

    // Header encryption KDF info strings
    /// Derives Alice's initial sending header key (HKs) from the X3DH shared secret.
    /// Bob uses the same value as his initial receiving header key (HKr).
    public static let hkAliceInfo  = Data("SophaxChat_HKAlice_v1".utf8)
    /// Derives Bob's initial next-sending header key (NHKs) from the X3DH shared secret.
    /// Alice uses the same value as her initial next-receiving header key (NHKr).
    public static let nhkBobInfo   = Data("SophaxChat_NHKBob_v1".utf8)

    /// Maximum number of skipped message keys stored per session.
    /// Prevents memory exhaustion attacks.
    public static let maxSkippedMessages: Int = 1000

    /// Maximum prekey bundle age in seconds (24 hours).
    /// Stale bundles are rejected to prevent replay attacks.
    public static let maxPreKeyBundleAge: TimeInterval = 86400
}

// MARK: - Errors

public enum SophaxError: Error, LocalizedError {
    case keyGenerationFailed
    case encryptionFailed(String)
    case decryptionFailed
    case invalidSignature
    case sessionNotInitialized
    case tooManySkippedMessages
    case invalidMessageFormat(String)
    case keyAgreementFailed
    case stalePreKeyBundle
    case keychainError(OSStatus)
    case sessionStateCorrupted
    case missingChainKey

    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate cryptographic key"
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .decryptionFailed:
            return "Decryption failed — invalid key or corrupted data"
        case .invalidSignature:
            return "Signature verification failed"
        case .sessionNotInitialized:
            return "Secure session not yet established"
        case .tooManySkippedMessages:
            return "Too many skipped messages in chain (possible attack)"
        case .invalidMessageFormat(let reason):
            return "Invalid message format: \(reason)"
        case .keyAgreementFailed:
            return "Key agreement failed"
        case .stalePreKeyBundle:
            return "Prekey bundle is too old or has an invalid timestamp"
        case .keychainError(let status):
            return "Keychain error (status: \(status))"
        case .sessionStateCorrupted:
            return "Session state is corrupted"
        case .missingChainKey:
            return "Chain key is missing — cannot encrypt/decrypt"
        }
    }
}
