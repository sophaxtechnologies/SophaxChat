# Security Architecture & Review

*Last reviewed: 2026-03-13. Reviewed against source code; not an independent external audit.*

---

## Threat Model

SophaxChat is designed to protect against:

| Threat | Mitigation |
|--------|-----------|
| Passive eavesdropping (network sniffing) | End-to-end encryption (Double Ratchet + ChaCha20-Poly1305) |
| Active MITM attack | Ed25519 signatures on every message; Safety Number QR verification |
| Server compromise | No servers — P2P only |
| Compromised device (past messages) | Forward secrecy (per-message keys via symmetric ratchet) |
| Compromised device (future messages) | Break-in recovery (Double Ratchet DH ratchet with fresh Curve25519 keys) |
| Metadata analysis | Anonymous identity (no phone/email); peerID = hash of identity keys |
| Replay attacks | Message authentication + unique nonces; message-ID deduplication at storage layer |
| Key exhaustion / DoS | Bounded skipped-key cache (max 1000); relay rate limiting (20/10s per peer) |
| Message forgery | Ed25519 signatures on all wire messages |
| Sender identity leakage to relay nodes | Sealed sender: ECDH(ephemeral, recipient DH) → ChaCha20-Poly1305 wraps inner message |
| Header metadata leakage to relay nodes | Header Encryption (HE) variant of Double Ratchet — headers sealed with rotating header keys |
| Physical data-at-rest access | AES-256-GCM encrypted message store + private keys in Keychain |
| iCloud backup exfiltration | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — keys never backed up or transferred |
| App switcher screenshot | Blur overlay on `willResignActive` |
| App access without biometric | App lock (Face ID / Touch ID / passcode, auto-lock on background) |
| DoS via oversized messages | Attachment ≤ 512 KB; username ≤ 64 chars |
| Prekey exhaustion | OTPK pool auto-replenished when below 50%; SPK rotated every 7 days |

---

## Cryptographic Primitives

All primitives are from Apple's **[CryptoKit](https://developer.apple.com/documentation/cryptokit)** (audited, hardware-accelerated):

| Layer | Operation | Algorithm | Key Size |
|-------|-----------|-----------|----------|
| Identity | Signing | Ed25519 | 256-bit |
| Identity | Key agreement | X25519 | 256-bit |
| Session init | Key exchange | X3DH (Signal spec) | — |
| Session init | Key derivation | HKDF-SHA256 | 256-bit |
| Messaging | Symmetric ratchet | HMAC-SHA256 | 256-bit |
| Messaging | DH ratchet | X25519 | 256-bit |
| Messaging | AEAD encryption | ChaCha20-Poly1305 | 256-bit |
| Header encryption | AEAD | ChaCha20-Poly1305 | 256-bit |
| Sealed sender | Key derivation | HKDF-SHA256 | 256-bit |
| Sealed sender | AEAD | ChaCha20-Poly1305 | 256-bit |
| Group Sender Keys | KDF chain | HMAC-SHA256 | 256-bit |
| Group encryption | AEAD | ChaCha20-Poly1305 | 256-bit |
| Storage | At-rest encryption | AES-256-GCM | 256-bit |
| Identity verification | Safety numbers | SHA-512 | — |
| Random number generation | OS CSPRNG | (via CryptoKit) | — |

---

## Protocol Details

### Session Establishment (X3DH)

Based on the [Signal X3DH specification](https://signal.org/docs/specifications/x3dh/).

```
Alice                                          Bob
──────────────────────────────────────────────────────
         ←─── Hello (Bob's PreKeyBundle) ────

Alice computes:
  EK_A = ephemeral key pair
  DH1 = DH(IK_A, SPK_B)    — identity auth
  DH2 = DH(EK_A, IK_B)     — ephemeral x identity
  DH3 = DH(EK_A, SPK_B)    — ephemeral x signed prekey
  DH4 = DH(EK_A, OPK_B)   [if OPK available]
  SK  = HKDF(0xFF×32 ∥ DH1 ∥ DH2 ∥ DH3 [∥ DH4])

         ──── InitiateSession (EK_A, first DR message) ────→

Bob computes: same DH operations symmetrically → same SK
```

### Message Encryption (Double Ratchet with Header Encryption)

Based on the [Signal Double Ratchet specification §4.3](https://signal.org/docs/specifications/doubleratchet/).

- **DH Ratchet**: New Curve25519 key pair generated on each direction change. Provides break-in recovery.
- **Symmetric Ratchet**: `KDF_CK(chainKey)` via HMAC-SHA256. Provides per-message forward secrecy.
- **Header Encryption**: `RatchetHeader` (ratchet public key, counters) is sealed with rotating header keys derived from the same HKDF chain. Relay nodes see only opaque ciphertext.
- **Body AEAD**: `ChaCha20-Poly1305(messageKey, plaintext, AAD = associatedData ∥ encryptedHeader)` — header and body are cryptographically bound.

### Sealed Sender

```
Sender generates ephemeral key pair (EK_s).
sharedSecret = ECDH(EK_s_private, recipient_DH_public)
sealingKey   = HKDF-SHA256(sharedSecret, info="SophaxChat_SealedSender_v1", len=32)
encryptedPayload = ChaChaPoly(sealingKey, JSON(innerWireMessage))
```

Relay nodes see origin + target + `EK_s_public` + ciphertext. The inner sender identity is revealed only to the recipient.

### Group Messaging (Sender Keys v2)

Each group member independently maintains a KDF chain:

```
messageKey_n   = HMAC-SHA256(chainKey_n, 0x01)   — encrypt/decrypt one message
chainKey_{n+1} = HMAC-SHA256(chainKey_n, 0x02)   — advance chain
```

The sender's chain key is distributed to all group members via the per-peer Double Ratchet channel (so only authenticated members can read it). Group messages are independently encrypted by each sender using their current message key, then broadcast to all members.

Properties:
- **Per-message forward secrecy**: Compromising `chainKey_n` exposes only messages ≥ n.
- **Break-in recovery**: Each sender independently ratchets; no shared state to compromise.
- **No transcript server**: Messages flood the local mesh; only members with valid chain keys can decrypt.

### Wire Message Authentication

Every network message is signed with the sender's Ed25519 identity key:

```
signingBytes = type ∥ payload ∥ senderID ∥ ISO8601(timestamp)
signature    = Ed25519.sign(signingBytes, with: signingPrivateKey)
```

Recipients verify this signature before processing. Session-initiation messages are self-authenticating (the verification key is carried inline in the bundle).

---

## Key Storage

| Key Material | Keychain Account | Access Control |
|---|---|---|
| Ed25519 identity signing key | `identity.signing` | WhenUnlockedThisDeviceOnly |
| X25519 identity DH key | `identity.dh` | WhenUnlockedThisDeviceOnly |
| Signed prekey | `spk.<id>` | WhenUnlockedThisDeviceOnly |
| One-time prekeys | `otpk.<id>` | WhenUnlockedThisDeviceOnly |
| Double Ratchet session state | `session.<peerID>` | WhenUnlockedThisDeviceOnly |
| Message storage master key | `storage.master` | WhenUnlockedThisDeviceOnly |
| Group sender key (my chain) | `skd.mine.<groupID>` | WhenUnlockedThisDeviceOnly |
| Group peer sender keys | `skd.peers.<groupID>` | WhenUnlockedThisDeviceOnly |
| Encrypted messages | App filesystem | AES-256-GCM encrypted |

`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
- Keys are **not** backed up to iCloud
- Keys are **not** transferred when setting up a new device
- Keys are **not** accessible when the device is locked
- Keys are wiped on factory reset

---

## Security Review Findings

### HIGH

#### H-1 — No group re-keying on member change
When a member leaves a group, remaining members continue using their existing sender key chains. The departed member retains all chain states from the time of departure and can decrypt any group traffic they subsequently capture. **There is no automatic re-keying on member leave or removal.**

*Mitigation required:* After a member change, all remaining members should generate fresh sender keys and redistribute them via the DR channel.

---

### MEDIUM

#### M-1 — Group sender key: skipped messages are irrecoverable
The receiver fast-forwards the sender chain up to `MAX_SKIP = 100` iterations for out-of-order delivery, but discards intermediate message keys (not cached). Any message that arrives after being skipped over cannot be decrypted.

*Recommendation:* Cache skipped message keys in a bounded table (as the Double Ratchet layer already does).

#### M-2 — Sender key distribution may arrive after messages in high-load scenarios
When a group member joins, their sender key distribution (SKD) is sent via the DR channel to all members. If the joiner's first group messages arrive before the SKD (possible in a high-traffic mesh), those messages cannot be decrypted.

*Recommendation:* Include the current chain state (not freshly generated) in subsequent SKD resends; or hold outgoing group messages briefly until SKD delivery is confirmed.

#### M-3 — One-time prekey exhaustion window
If Bob's OTPK pool is empty, Alice initiates X3DH without DH4, removing the one-time component from the session secret. Auto-replenishment occurs when the pool falls below 50%, but there is a brief window of reduced security.

#### M-4 — Notification previews may expose content on lock screen
`UNNotificationContent` previews are shown on the lock screen by default, potentially revealing message content before the user unlocks the app.

*Recommendation:* Set `hiddenPreviewsBodyPlaceholder` and use `UNNotificationContent.threadIdentifier` to group without revealing content.

---

### LOW

#### L-1 — No transcript consistency for groups
Decentralized group messaging cannot guarantee all members receive the same messages in the same order without a trusted coordinator or threshold scheme. A malicious member can selectively withhold or reorder messages.

#### L-2 — Group message timestamps are sender-controlled
`GroupWireMessage.timestamp` is set by the sender. A malicious or clock-skewed sender can cause messages to appear in the wrong order in the UI.

#### L-3 — `ISO8601DateFormatter` allocated per `signingBytes()` call
Performance micro-issue; no security impact.

---

## What SophaxChat Does NOT Protect Against

- **Traffic analysis**: Packet timing and size correlations on the mesh can reveal communication patterns.
- **Endpoint compromise**: A compromised device has access to all Keychain material and plaintext in memory.
- **Selective delivery attacks**: Group members can selectively withhold messages from other members.
- **Identity bootstrapping (TOFU)**: First contact is trust-on-first-use. Safety Number QR scan is the only out-of-band verification mechanism.
- **Physical device seizure**: Bypasses all software-layer protections.
- **Bluetooth range limitations**: Mesh is limited to ~100m (WiFi Direct) or ~30m (Bluetooth LE).
- **No key recovery**: If a device is wiped or lost, all message history and identity keys are permanently gone. There is intentionally no backup or recovery mechanism.

---

## Responsible Disclosure

Please **do not open public GitHub issues** for security vulnerabilities.

Use **[GitHub Security Advisories](https://github.com/sophaxtechnologies/SophaxChat/security/advisories/new)** — private, end-to-end encrypted between reporter and maintainers, no central server involved.

We aim to respond within 72 hours. Coordinated disclosure window: 90 days.
