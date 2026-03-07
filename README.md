# SophaxChat

**Maximally secure, open-source, serverless P2P chat for iOS.**

Inspired by [Signal](https://signal.org) and [bitchat](https://github.com/jackjackbits/bitchat).

> ⚠️ **Alpha — not yet production-ready.** The cryptographic primitives are sound, but the app has not been independently audited.

---

## Features

- **End-to-end encrypted** — Signal Protocol: X3DH + Double Ratchet
- **No servers** — messages travel directly over Bluetooth LE and WiFi Direct (MultipeerConnectivity)
- **Anonymous** — no phone number, email, or account required. Identity = a cryptographic key pair.
- **Forward secrecy** — every message uses a unique key. Past messages stay safe.
- **Break-in recovery** — future messages become secure again after a key compromise.
- **Open-source** — full audit trail

---

## Cryptography

| Operation | Algorithm |
|-----------|-----------|
| Session establishment | X3DH (Extended Triple Diffie-Hellman) |
| Forward secrecy | Double Ratchet Algorithm |
| Key agreement | Curve25519 / X25519 |
| Signing | Ed25519 |
| Message encryption | ChaCha20-Poly1305 |
| Key derivation | HKDF-SHA256 |
| Chain ratchet | HMAC-SHA256 |
| Storage encryption | AES-256-GCM |

All primitives are from Apple's **CryptoKit** — hardware-accelerated and audited.

See [SECURITY.md](SECURITY.md) for the full threat model and protocol description.

---

## Architecture

```
SophaxChat/
├── Sources/SophaxChatCore/        # Core library (testable, portable)
│   ├── Crypto/
│   │   ├── CryptoTypes.swift      # Types, constants, errors
│   │   ├── KeychainManager.swift  # Secure key storage (iOS Keychain)
│   │   ├── IdentityManager.swift  # User identity (Ed25519 + X25519)
│   │   ├── PreKeyManager.swift    # X3DH prekey management
│   │   ├── X3DH.swift            # X3DH key agreement
│   │   └── DoubleRatchet.swift   # Double Ratchet algorithm
│   ├── Network/
│   │   ├── NetworkProtocol.swift  # Wire message definitions
│   │   └── MeshManager.swift     # MultipeerConnectivity P2P mesh
│   ├── Storage/
│   │   └── MessageStore.swift    # Encrypted at-rest message storage
│   └── ChatManager.swift         # High-level coordinator
├── SophaxChat/                    # iOS SwiftUI app
│   ├── App/
│   │   ├── SophaxChatApp.swift
│   │   └── AppState.swift
│   └── Views/
│       ├── Onboarding/OnboardingView.swift
│       ├── Chat/ChatListView.swift
│       ├── Chat/ChatView.swift
│       ├── Chat/MessageBubbleView.swift
│       └── Settings/IdentityView.swift
└── Tests/SophaxChatCoreTests/
    └── CryptoTests.swift          # X3DH + Double Ratchet unit tests
```

---

## Getting Started

### Requirements
- Xcode 15+
- iOS 17+
- Two physical iOS devices (MultipeerConnectivity does not work in the Simulator for P2P)

### Build

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen):
   ```sh
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```sh
   xcodegen generate
   ```

3. Open `SophaxChat.xcodeproj` in Xcode.

4. Set your development team in the project settings.

5. Build and run on two devices.

### Tests

```sh
swift test
```

Or run via Xcode → Product → Test (⌘U).

---

## Security Notes

- Keys are stored in the iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — not backed up to iCloud, not transferable.
- Messages are encrypted at rest with AES-256-GCM.
- The app blurs its content when moved to the background (prevents screenshot in App Switcher).
- Identity verification via Safety Numbers — compare with your contact out-of-band (in person or voice call).

---

## Roadmap

- [ ] Header encryption (hides metadata in Double Ratchet headers)
- [ ] Sealed Sender (hides sender identity at transport layer)
- [ ] Disappearing messages
- [ ] Group messaging (Sender Keys or MLS)
- [ ] QR code for Safety Number verification
- [ ] macOS support (Catalyst)
- [ ] Independent security audit

---

## Contributing

Pull requests welcome. Please read [SECURITY.md](SECURITY.md) before contributing to crypto-related code.

**Security vulnerabilities**: report privately to security@sophax.com — do not open public issues.

---

## License

MIT — see [LICENSE](LICENSE).
