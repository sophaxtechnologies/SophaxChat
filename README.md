<div align="center">
  <img src="sophaxchat_logo.png" alt="SophaxChat" width="160" />

  <h1>SophaxChat</h1>

  <p><strong>Signal-grade encryption. No servers. No accounts. Mesh-first, internet-optional.</strong></p>

  <p>
    <img src="https://img.shields.io/badge/Swift-6.2-FA7343?logo=swift&logoColor=white" />
    <img src="https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white" />
    <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" />
    <img src="https://img.shields.io/badge/License-MIT-blue" />
    <img src="https://img.shields.io/badge/Status-Alpha-orange" />
    <img src="https://img.shields.io/badge/Cryptography-CryptoKit-34C759?logo=apple" />
  </p>

  <p>
    <a href="#protocol">Protocol</a> •
    <a href="#cryptography">Cryptography</a> •
    <a href="#features">Features</a> •
    <a href="#architecture">Architecture</a> •
    <a href="#getting-started">Getting Started</a> •
    <a href="#security">Security</a> •
    <a href="#roadmap">Roadmap</a>
  </p>

  <br />

  > ⚠️ **Alpha — not yet production-ready.** Cryptographic primitives are sound, but the codebase has not been independently audited. Do not rely on it for life-critical anonymity.

</div>

---

## What is SophaxChat?

SophaxChat is an **open-source, infrastructure-free, end-to-end encrypted** messenger for iOS and macOS. It works over Bluetooth LE and WiFi Direct by default — no internet required, no servers, no phone number, no account.

When you need to reach someone across the world, an optional TCP transport lets you connect peer-to-peer over the internet. The **recommended way** to use this is through **[Orbot](https://apps.apple.com/app/orbot/id1609461599)** (Tor VPN mode) — which routes your TCP traffic anonymously through Tor with zero configuration inside SophaxChat. The cryptographic layer is identical regardless of transport.

Every message is protected by the **Signal Protocol** (X3DH + Double Ratchet with Header Encryption). Your identity is nothing more than a cryptographic key pair generated on your device.

> **Is it still "Anonymous, offline, end-to-end encrypted mesh chat"?**
> Yes — and more. Local mode (BLE/WiFi) is fully offline and anonymous as always. With TCP enabled via Orbot/Tor, it becomes *global*: still anonymous (no account, no phone number), still end-to-end encrypted (same X3DH + Double Ratchet pipeline), still decentralized (no servers — direct peer-to-peer). TCP and Tor support are optional and off by default.

### Who is SophaxChat for?

**Journalists and activists** — communicate without leaving traces tied to a phone number or account. Combine with Tor (Orbot VPN mode) for transport anonymity.

**Disaster responders and field workers** — no internet? Bluetooth and WiFi mesh still work. Devices relay messages across the network automatically, up to 6 hops.

**Privacy-conscious users** — tired of surrendering your phone number to chat apps. Here, your identity is a cryptographic key pair, generated locally, never shared with any server.

**Developers and researchers** — the full source is open. Cryptographic primitives (X3DH, Double Ratchet, Header Encryption, Sealed Sender) are implemented in ~3 500 lines of auditable Swift using Apple's CryptoKit.

### Philosophy

SophaxChat is built around three principles that cannot be traded away:

1. **No servers, ever.** Servers are honeypots. Every central point is a single point of failure, surveillance, and censorship. SophaxChat communicates directly device-to-device — over Bluetooth, WiFi, and peer-to-peer TCP. The Tor network (via Orbot) provides internet routing without introducing any trusted server.

2. **No identity leakage.** No phone number, no email, no account. Your identity is a Curve25519 key pair, generated on your device, never transmitted to any server. The app doesn't even know your name unless you choose to set one.

3. **Maximum cryptographic protection, not just "good enough".** X3DH gives each session unique key material. Double Ratchet rotates keys every message. Header Encryption hides routing metadata from relay nodes. Sealed Sender hides who is talking to whom. These are not features — they are the baseline.

### Why does it exist?

| Scenario | Signal | bitchat | SophaxChat |
|---|:---:|:---:|:---:|
| No internet connection (BLE/WiFi mesh) | ❌ | ✅ | ✅ |
| Internet reach (TCP, peer-to-peer) | ✅ | ❌ | ✅ |
| Tor / anonymity network support | ⚠️ | ❌ | ✅ |
| No phone number required | ❌ | ✅ | ✅ |
| Signal-grade forward secrecy | ✅ | ❌ | ✅ |
| Per-session unique keys (X3DH) | ✅ | ❌ | ✅ |
| Header encryption (relay metadata) | ✅ | ❌ | ✅ |
| Sealed sender (hides sender from relay) | ✅ | ❌ | ✅ |
| No server dependency | ❌ | ✅ | ✅ |
| Group messaging (Sender Keys) | ✅ | ❌ | ✅ |
| Open-source | ⚠️ | ✅ | ✅ |
| Multihop relay (mesh routing) | ❌ | ✅ | ✅ |
| macOS support | ✅ | ❌ | ✅ |

SophaxChat occupies a specific niche: **Signal-grade cryptography, zero infrastructure**. Ideal for journalists, activists, protesters, disaster responders, or anyone in an environment where internet access is unavailable, monitored, or untrusted.

---

## Protocol

### 1:1 Session Lifecycle

```
┌─ Alice ─────────────────────────────────────────────────────────── Bob ─┐

  [1. DISCOVERY — MultipeerConnectivity (Bluetooth LE / WiFi Direct)]

      Alice ←──── MPC peer found ────→ Bob

  [2. HELLO — Immediate key exchange on connection]

      Alice ──── Hello(PreKeyBundle_A) ────→ Bob
      Alice ←─── Hello(PreKeyBundle_B) ──── Bob

  [3. SESSION INIT — X3DH key agreement, first encrypted message]

      Alice computes:
        DH1 = DH(IK_A, SPK_B)
        DH2 = DH(EK_A, IK_B)
        DH3 = DH(EK_A, SPK_B)
        DH4 = DH(EK_A, OPK_B)  [if available]
        SK  = HKDF(DH1 || DH2 || DH3 || DH4)

      Alice ──── InitiateSession(EK_A, usedKeyIDs, DR_msg_0) ────→ Bob
                                                         Bob derives SK from his keys
                                                         Bob inits Double Ratchet

  [4. MESSAGES — Double Ratchet + Header Encryption]

      Alice ──── SealedSender(encHeader, encBody) ────→ Bob
      Alice ←─── SealedSender(encHeader, encBody) ──── Bob

  [5. RELAY — If Alice and Bob not directly connected]

      Alice ──── Relay(TTL=6, target=Bob, msg) ────→ Charlie ────→ Bob
                                                     (TTL=5)

└─────────────────────────────────────────────────────────────────────────┘
```

### Group Session Lifecycle

```
┌─ Alice (creator) ─────────────────────── Bob, Carol ─┐

  [1. CREATE — Alice generates group and her sender chain]

      Alice: senderChainKey_A = random(32 bytes)

  [2. INVITE — Sent via per-peer Double Ratchet channel]

      Alice ──── GroupInvite(groupID, senderChainKey_A) ────→ Bob
      Alice ──── GroupInvite(groupID, senderChainKey_A) ────→ Carol

  [3. JOIN — Each member generates their own sender chain]

      Bob:   senderChainKey_B = random(32 bytes)
      Carol: senderChainKey_C = random(32 bytes)

      Bob   ──── SenderKeyDistribution(senderChainKey_B) ────→ Alice, Carol
      Carol ──── SenderKeyDistribution(senderChainKey_C) ────→ Alice, Bob

  [4. GROUP MESSAGE — Each sender uses their own KDF chain]

      messageKey_n   = HMAC-SHA256(chainKey_n, 0x01)
      chainKey_{n+1} = HMAC-SHA256(chainKey_n, 0x02)

      Alice ──── GroupMsg(ciphertext, iteration=n) ────→ Bob, Carol
                                    (broadcast via mesh)

└──────────────────────────────────────────────────────┘
```

### Key Properties

- **Forward secrecy** — each message uses a unique message key. Compromising key `n` reveals nothing about keys `< n`.
- **Break-in recovery** — after a compromise, DH ratchet steps generate fresh key material from new Curve25519 ephemeral keys. Each group member ratchets independently.
- **Header encryption** — ratchet headers (public key, counters) are sealed with rotating header keys. Relay nodes see only opaque ciphertext.
- **Sealed sender** — sender identity is hidden from relay nodes; only the intended recipient can learn who sent the message.
- **Multihop relay** — messages flood through the mesh with TTL=6, deduplicated via LRU cache.
- **Offline queue** — messages queued in memory when no peers are reachable; drained automatically on reconnect.
- **Disappearing messages** — optional `expiresAt` timestamp; messages purged locally every 60 seconds. Supported in both 1:1 and group conversations.

---

## Cryptography

All primitives come from Apple's **[CryptoKit](https://developer.apple.com/documentation/cryptokit)** — hardware-accelerated and independently audited by Apple.

| Layer | Operation | Algorithm | Key Size |
|---|---|---|---|
| Identity | Signing | Ed25519 | 256-bit |
| Identity | Key agreement | X25519 | 256-bit |
| Session init | Key exchange | X3DH | — |
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

### Key Storage

All private keys and session states are stored in the **iOS Keychain** with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:

- Not backed up to iCloud
- Not transferred to a new device
- Not accessible when the device is locked
- Wiped on device factory reset

---

## Features

### Messaging

| Feature | 1:1 | Group |
|---|:---:|:---:|
| Text messages | ✅ | ✅ |
| Image sharing | ✅ | ✅ |
| Voice messages (PTT, AAC M4A) | ✅ | ✅ |
| Reply to message (quoted bubble) | ✅ | ✅ |
| Message reactions (6-emoji) | ✅ | ✅ |
| Read receipts (blue tick) | ✅ | ✅ |
| Disappearing messages (30s–7d) | ✅ | ✅ |
| Forward message | ✅ | ✅ |
| Message search | ✅ | ✅ |

### Groups

| Feature | Status |
|---|---|
| Create group (multi-peer picker) | ✅ |
| Signal-style Sender Keys (per-member KDF chain) | ✅ |
| Group invite via Double Ratchet channel | ✅ |
| Sender Key Distribution to all members | ✅ |
| Per-message forward secrecy (per-member) | ✅ |
| Leave group | ✅ |
| Member list sheet | ✅ |
| Group push notifications | ✅ |
| Out-of-order message recovery (skipped key cache, 200 keys/sender) | ✅ |
| Re-keying on member leave (forward secrecy) | ✅ |

### Security & Privacy

| Feature | Status |
|---|---|
| X3DH session establishment | ✅ |
| Double Ratchet + Header Encryption | ✅ |
| Sealed sender | ✅ |
| Ed25519 message signatures | ✅ |
| Safety Number verification (QR + manual) | ✅ |
| App lock (Face ID / Touch ID / passcode) | ✅ |
| Auto-lock on background | ✅ |
| App Switcher blur | ✅ |
| AES-256-GCM at-rest message storage | ✅ |
| Block peer | ✅ |
| TOFU key-change warning (Safety Number changed banner) | ✅ |
| Notification content hiding on lock screen (M-4) | ✅ |

### Network & Transport

| Feature | Status |
|---|---|
| Bluetooth LE transport | ✅ |
| WiFi Direct transport | ✅ |
| TCP internet transport (peer-to-peer, no server) | ✅ |
| Tor / SOCKS5 anonymity (Orbot VPN mode or proxy) | ✅ |
| Multihop relay (TTL=6) | ✅ |
| LRU relay deduplication | ✅ |
| Offline message queue | ✅ |
| Rate limiting (20 relays / 10s per peer) | ✅ |
| Relay hop indicator in UI | ✅ |
| Typing indicators | ✅ |
| Store-and-forward via relay peers (48h TTL, 300 items) | ✅ |
| macOS Catalyst support | ✅ |

---

## Architecture

```
SophaxChat/
├── Sources/SophaxChatCore/          # Core library — pure Swift, testable
│   ├── Crypto/
│   │   ├── CryptoTypes.swift        # Types, constants, error definitions
│   │   ├── KeychainManager.swift    # Keychain CRUD for all key material
│   │   ├── IdentityManager.swift    # Ed25519 + X25519 identity lifecycle
│   │   ├── PreKeyManager.swift      # X3DH prekey pool (SPK + 20 OTPKs)
│   │   ├── X3DH.swift              # X3DH sender and receiver implementation
│   │   └── DoubleRatchet.swift     # Double Ratchet + Header Encryption (Signal spec §4.3)
│   ├── Group/
│   │   └── GroupTypes.swift        # GroupInfo, SenderKeyState, SenderKeyDistributionMessage
│   ├── Network/
│   │   ├── NetworkProtocol.swift   # Wire message types + WireMessageBuilder
│   │   ├── MeshManager.swift       # MultipeerConnectivity P2P transport (BLE/WiFi)
│   │   ├── TCPTransport.swift      # Internet TCP transport (SOCKS5/Tor, port 25519)
│   │   └── RelayRouter.swift       # Multihop relay with LRU dedup cache
│   ├── Storage/
│   │   ├── MessageStore.swift      # AES-256-GCM encrypted at-rest storage
│   │   └── AttachmentStore.swift   # Encrypted blob store for images/audio
│   └── ChatManager.swift           # High-level coordinator (session + routing)
│
├── SophaxChat/                      # iOS/macOS SwiftUI application
│   ├── App/
│   │   ├── SophaxChatApp.swift     # App entry point + blur-on-background
│   │   └── AppState.swift          # @MainActor observable state
│   └── Views/
│       ├── Onboarding/             # First-run username setup
│       ├── Chat/                   # Chat list, 1:1 and group bubbles, relay indicator
│       └── Settings/               # Safety number verification, app lock
│
└── Tests/SophaxChatCoreTests/
    └── CryptoTests.swift           # X3DH symmetry + Double Ratchet correctness
```

> **macOS:** The app runs on macOS 14+ via Catalyst. `AVAudioSession` calls are guarded with `#if !targetEnvironment(macCatalyst)`. Peer discovery works over WiFi on macOS.

### Data Flow

```
SwiftUI View
    │  sendMessage() / sendGroupMessage()
    ▼
AppState (@MainActor)
    │
    ▼
ChatManager                  ← single coordinator, NSLock session mutex
    │
    ├─ 1:1 path
    │   ├─ buildOutboundWire()   ← X3DH init (new session) or DR+HE encrypt
    │   ├─ sealedSenderWrap()    ← ECDH(ephemeral, recipientDH) → ChaChaPoly
    │   └─ sendOrQueue()
    │           ├─ tcp.send()            if peer connected via TCP/internet
    │           ├─ mesh.send()           if peer directly connected (BLE/WiFi)
    │           ├─ mesh.broadcast()      relay via RelayEnvelope (TTL=6)
    │           └─ pendingQueue[]        offline; drained on reconnect
    │
    ├─ group path
    │   ├─ senderKeyRatchetStep()  ← HMAC-SHA256(chainKey, 0x01/0x02)
    │   ├─ ChaChaPoly encrypt      ← with per-message key
    │   └─ mesh.broadcast()        ← GroupWireMessage to all members
    │
    └─ didReceiveMessage()
            ├─ .hello                  → store PreKeyBundle, drain queue
            ├─ .initiateSession        → X3DH receiver, DR init, decrypt
            ├─ .message                → DR+HE decrypt, send ACK
            ├─ .ack / .readReceipt     → update message status
            ├─ .relay                  → process inner or forward (TTL-1)
            ├─ .groupInvite            → store group, generate sender chain, distribute SKD
            ├─ .groupMessage           → v2: ratchet peer chain; v1: shared key fallback
            └─ .senderKeyDistribution  → store peer sender chain state
```

---

## Getting Started

### Requirements

| Requirement | Version |
|---|---|
| Xcode | 16.0+ |
| iOS deployment target | 17.0+ |
| macOS deployment target | 14.0+ (Catalyst) |
| Physical devices | 2× iPhone (MultipeerConnectivity requires real hardware) |
| XcodeGen | latest |

> **Note:** The Swift core library (`SophaxChatCore`) builds without Xcode via `swift build`. Physical devices are required to test P2P connectivity; the simulator does not support MultipeerConnectivity peer discovery.

### Build

```sh
# 1. Clone
git clone https://github.com/sophaxtechnologies/SophaxChat.git
cd SophaxChat

# 2. Install XcodeGen
brew install xcodegen

# 3. Generate Xcode project
xcodegen generate

# 4. Open in Xcode
open SophaxChat.xcodeproj
```

Then in Xcode:
1. Select your development **Team** in the project settings (Signing & Capabilities)
2. Choose a physical device as the build target
3. **⌘R** to build and run

Repeat on the second device.

### Verify the core library (no Xcode needed)

```sh
swift build
```

### Tests

```sh
# Run in Xcode (Swift Testing framework)
# Product → Test  (⌘U)
```

Tests cover: X3DH key symmetry (with/without OTPK), Double Ratchet bidirectional messaging, out-of-order message delivery, session state persistence, associated data binding, and KDF distinctness.

---

## Security

See [SECURITY.md](SECURITY.md) for the full threat model, cryptographic primitive table, protocol details, and security review findings.

### What SophaxChat protects against

| Threat | Protection |
|---|---|
| Network eavesdropping | ChaCha20-Poly1305 E2EE; MPC transport encrypted (`.required`); TCP is a carrier of already-sealed WireMessages |
| MITM / impersonation | Ed25519 signatures on every message; Safety Number verification |
| Replay attacks | Unique nonce per message; message-ID deduplication at storage layer |
| Past message compromise | Forward secrecy via symmetric ratchet (per-message keys) |
| Future message compromise | Break-in recovery via DH ratchet (fresh Curve25519 ephemeral keys) |
| Header metadata leakage | Header Encryption — relay nodes see only opaque ciphertext |
| Sender identity leakage | Sealed sender — sender hidden from relay nodes via ECDH wrapping |
| Data at rest | AES-256-GCM encrypted message and attachment store |
| iCloud backup exfiltration | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; keys never backed up |
| App Switcher screenshot | Content blurred on `willResignActive` |
| Unauthorized app access | App lock: Face ID / Touch ID / passcode, auto-lock on background |
| DoS via oversized messages | Attachment ≤ 512 KB; username ≤ 64 chars |
| Prekey exhaustion | OTPK pool auto-replenished when below 50%; SPK rotated every 7 days |

### Identity verification

Each user has a **Safety Number** — a 60-digit fingerprint derived from SHA-512 of their identity keys. Both numbers are shown side by side in the verification screen: each party reads their own number aloud to the other. Scan via QR code or compare manually.

### Known limitations

See [SECURITY.md § Security Review Findings](SECURITY.md) for full details. Key items:

| Finding | Severity | Summary |
|---|---|---|
| ~~H-1~~ | ~~HIGH~~ | ~~No group re-keying on member leave~~ — **fixed**: fresh sender chain rotated on every membership change |
| ~~M-1~~ | ~~MEDIUM~~ | ~~Group skipped message keys not cached~~ — **fixed**: bounded cache (200 keys/sender) with auto-eviction |
| M-2 | MEDIUM | Sender Key Distribution may arrive after first messages in high-load scenarios |
| M-3 | MEDIUM | One-time prekey exhaustion window reduces X3DH entropy temporarily |
| ~~M-4~~ | ~~MEDIUM~~ | ~~Notification previews may expose content on lock screen~~ — **fixed**: `hiddenPreviewsBodyPlaceholder` registered |

### Responsible Disclosure

Do not open public issues for security bugs.

---

## Roadmap

### Completed

- [x] X3DH session establishment
- [x] Double Ratchet messaging
- [x] Header Encryption (Double Ratchet extension — hides ratchet metadata from relay)
- [x] Sealed sender (hides sender identity from relay nodes)
- [x] Multihop relay (TTL flooding + LRU dedup)
- [x] Offline message queue
- [x] Disappearing messages (30s–7d, per-message expiry, 1:1 and group)
- [x] SPK rotation (7-day automatic)
- [x] OTPK replenishment
- [x] Safety Numbers (manual + QR scan)
- [x] Rate limiting on relay forwarding (20 / 10s per peer)
- [x] Session initiation deduplication
- [x] Push-to-talk voice messages (AAC M4A, encrypted)
- [x] Image sharing (encrypted, tap-to-zoom, PhotosPicker + camera)
- [x] Unread message badges
- [x] Delete conversation + block peer
- [x] Reply to message (quoted bubble, context menu)
- [x] Read receipts (blue tick)
- [x] App lock (Face ID / Touch ID / passcode, auto-lock on background)
- [x] Contact renaming
- [x] Local push notifications (grouped by thread, cleared on read)
- [x] Forward message
- [x] Message search (per-conversation)
- [x] Message reactions (6-emoji picker, tappable pill row)
- [x] Group messaging (Signal-style Sender Keys — per-member KDF chains)
- [x] Group images and voice messages
- [x] Group disappearing messages
- [x] Group member list + leave group
- [x] macOS Catalyst support
- [x] Group re-keying on member leave (H-1 — fresh sender chain on every membership change)
- [x] Group skipped message key cache (M-1 — bounded 200 keys/sender, auto-eviction)
- [x] Notification content hiding on lock screen (M-4 — `hiddenPreviewsBodyPlaceholder`)
- [x] TOFU key-change detection (Safety Number changed banner)
- [x] PrivacyInfo.xcprivacy (App Store privacy manifest)
- [x] Store-and-forward via relay peers (48h TTL, up to 300 items, delivered on reconnect)

### Completed (continued)

- [x] Background operation — `bluetooth-central` + `bluetooth-peripheral` background modes declared; `BGAppRefreshTask` registered (`com.sophax.mesh-refresh`) to restart the mesh briefly after iOS suspends the process and drain any pending queues. MPC sessions survive for several minutes after backgrounding with BLE background modes alone.
- [x] Channel discovery — `ChannelAnnouncement` wire message type added. Group creators broadcast signed announcements to all nearby peers (1 hop). Non-members see a "Nearby Channels" section in the conversation list; they can contact the creator to request an invite.
- [x] Pluggable transport adapter — `MessageTransport` protocol defined in `Network/MessageTransport.swift`. `MeshManager` is the production implementation (MultipeerConnectivity). Future adapters (LoRa, acoustic covert channel) implement the same `start/stop/send/broadcast/isConnected` surface. Adapter stubs and specification notes are in the protocol file.
- [x] TCP internet transport — `TCPTransport.swift` (Network.framework, iOS 17+). 4-byte length-prefix framing, Hello exchange on connect, SOCKS5/Tor proxy support. ChatManager routes to TCP first when the peer is connected, falling back to BLE/WiFi mesh. Off by default; toggled in Settings under "Internet Mode".
- [x] Internet mode Settings UI — TCP toggle, port field, public address entry ("My Address"), SOCKS5 proxy field, direct connect button (enter peer's host:port).

### Seeking external support

- [ ] **Independent third-party security audit** — highest-priority post-v1.0 item. Target: [NLnet / NGI Zero](https://nlnet.nl/NGI0/) grant. Contact security@sophax.com if you are interested in auditing.
- [ ] **Hardware security key binding** — Secure Enclave identity key storage (migration path needed for existing installs) and FIDO2 external key support (requires ASAuthorizationSecurityKeyPublicKeyCredentialProvider, iOS 16+). Planned post-audit.

---

## Contributing

Pull requests are welcome. Before contributing:

1. Read [SECURITY.md](SECURITY.md) — especially if touching crypto code
2. Open an issue to discuss significant changes before writing code
3. All cryptographic changes require a corresponding test in `CryptoTests.swift`
4. Run `swift build` before submitting

### Areas where help is especially welcome

- **UI/UX** — the interface is functional, not polished
- **Tests** — relay dedup, group sender key, session initiation edge cases
- **Localization** — the app currently ships in English only
- **LoRa / audio transport** — implement `MessageTransport` for LoRa radio or near-ultrasonic audio channel (see `Network/MessageTransport.swift`)

---

<!-- Support section — hidden until BTC/XMR addresses are configured
## Support

SophaxChat is free, open-source, and always will be. No ads, no subscriptions, no data collection — ever.

If you find it useful, you can support continued development anonymously:

| Currency | Address |
|----------|---------|
| **Bitcoin (BTC)** | `YOUR_BTC_ADDRESS_HERE` |
| **Monero (XMR)** | `YOUR_XMR_ADDRESS_HERE` |

Monero is recommended — it's privacy-preserving by design, consistent with everything this project stands for.

You can also ⭐ star the repo, share it, or submit a pull request.
-->

---

## License

MIT — see [LICENSE](LICENSE).

```
Copyright (c) 2026 Sophax Technologies

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```

---

<div align="center">
  <sub>Built with ❤️ and paranoia. No servers were harmed in the making of this app.</sub>
</div>
