# Security Architecture

## Threat Model

SophaxChat is designed to protect against:

| Threat | Mitigation |
|--------|-----------|
| Passive eavesdropping (network sniffing) | End-to-end encryption (Double Ratchet + ChaCha20-Poly1305) |
| Active MITM attack | Safety numbers (out-of-band identity verification) |
| Server compromise | No servers — P2P only |
| Compromised device (past messages) | Forward secrecy (every message has a unique key) |
| Compromised device (future messages) | Break-in recovery (Double Ratchet DH ratchet) |
| Metadata analysis | Anonymous identity (no phone/email); transport-layer peer IDs are key hashes |
| Replay attacks | Message authentication + unique nonces per message |
| Key exhaustion / DoS | Bounded skipped message key cache (max 1000) |
| Message forgery | Ed25519 signatures on all wire messages |
| Physical device access (data at rest) | AES-256-GCM encrypted message store + keys in Keychain |
| iCloud backup exfiltration | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — keys not backed up |
| App switcher screenshot | Blur overlay on `willResignActive` |

## Cryptographic Primitives

All primitives are from Apple's **CryptoKit** framework (audited, hardware-accelerated):

| Operation | Algorithm | Key Size |
|-----------|-----------|----------|
| Identity signing | Ed25519 (Curve25519.Signing) | 256-bit |
| Key agreement | X25519 (Curve25519.KeyAgreement) | 256-bit |
| Session key derivation | X3DH (HKDF-SHA256) | 256-bit |
| Forward secrecy ratchet | Double Ratchet (HMAC-SHA256 + HKDF-SHA256) | 256-bit |
| Message encryption | ChaCha20-Poly1305 (ChaChaPoly) | 256-bit |
| Message auth tag | Poly1305 | 128-bit |
| Storage encryption | AES-256-GCM | 256-bit |
| Hash (fingerprints) | SHA-256, SHA-512 | — |

## Protocol Overview

### Session Establishment (X3DH)

Based on the [Signal X3DH specification](https://signal.org/docs/specifications/x3dh/).

```
Alice                                          Bob
──────────────────────────────────────────────────────
         ←─── Hello (Bob's PreKeyBundle) ────

Alice computes:
  EK_A = ephemeral key pair
  DH1 = DH(IK_A, SPK_B)
  DH2 = DH(EK_A, IK_B)
  DH3 = DH(EK_A, SPK_B)
  DH4 = DH(EK_A, OPK_B)   [if OPK available]
  SK  = HKDF(DH1 ∥ DH2 ∥ DH3 [∥ DH4])

         ──── InitiateSession (EK_A, first DR message) ────→

Bob computes:
  DH1 = DH(SPK_B, IK_A)   [symmetric to Alice's]
  DH2 = DH(IK_B, EK_A)
  DH3 = DH(SPK_B, EK_A)
  DH4 = DH(OPK_B, EK_A)   [if OPK was used]
  SK  = HKDF(...)          [same as Alice's]
```

### Message Encryption (Double Ratchet)

Based on the [Signal Double Ratchet specification](https://signal.org/docs/specifications/doubleratchet/).

- **DH Ratchet**: New Curve25519 key pair generated every time the conversation direction changes. Provides break-in recovery.
- **Symmetric Ratchet**: HMAC-SHA256 chain advancing with each message. Provides forward secrecy.
- **AEAD**: ChaCha20-Poly1305 with the message header as additional authenticated data.

### Wire Message Authentication

Every network message is signed with the sender's Ed25519 identity key:

```
signature = Ed25519.sign(type ∥ payload ∥ senderID ∥ timestamp, with: IK_signing)
```

Recipients verify this signature before processing any message.

## Key Storage

| Key | Storage | Access Control |
|-----|---------|---------------|
| Ed25519 identity signing key | iOS Keychain | WhenUnlockedThisDeviceOnly |
| X25519 identity DH key | iOS Keychain | WhenUnlockedThisDeviceOnly |
| Signed prekey | iOS Keychain | WhenUnlockedThisDeviceOnly |
| One-time prekeys | iOS Keychain | WhenUnlockedThisDeviceOnly |
| Session state (Double Ratchet) | iOS Keychain | WhenUnlockedThisDeviceOnly |
| Message storage key | iOS Keychain | WhenUnlockedThisDeviceOnly |
| Encrypted messages | App filesystem | Encrypted with AES-256-GCM |

`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` means:
- Keys are **not** backed up to iCloud
- Keys are **not** transferred when setting up a new device
- Keys are **not** accessible when the device is locked

## Known Limitations (MVP)

1. **No header encryption**: The Double Ratchet header (ratchet public key, message number) is visible to transport observers. Full header encryption is planned.
2. **No sealed sender**: The sender's peerID is included in the wire message envelope. Signal's Sealed Sender hides this.
3. **No disappearing messages**: Messages are stored indefinitely. Timed deletion is planned.
4. **Bluetooth range**: P2P mesh is limited to ~100m (WiFi Direct) or ~30m (BT LE).
5. **Offline messages**: If the recipient is not online, messages cannot be delivered (no store-and-forward server).
6. **No group messaging**: MVP supports 1:1 only. Group messaging requires additional protocol work (Sender Keys or MLS).

## Responsible Disclosure

Security vulnerabilities should be reported to: **security@sophax.com**

Please do not open public GitHub issues for security bugs.
