# Privacy Policy — SophaxChat

*Last updated: 2026-03-15*

## The short version

SophaxChat collects nothing. There are no servers. There is no company watching you.

## What data SophaxChat collects

**None.** SophaxChat does not collect, transmit, store, or share any personal data with any third party — because there is no third party. There is no server, no backend, no analytics, no crash reporting, no telemetry.

## What stays on your device

The following data exists only on your device and is never transmitted anywhere except directly to the peer you are communicating with:

- Your display name (chosen by you at first launch)
- Your cryptographic identity keys (Ed25519 + X25519 key pairs, stored in iOS Keychain)
- Your messages (encrypted at rest with AES-256-GCM, stored in Application Support)
- App settings (stored in UserDefaults: aliases, disappearing message timers, app lock toggle)

All of the above is encrypted on your device and inaccessible to SophaxChat, to any server, and to iCloud backup (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).

## How messages are transmitted

Messages travel directly from your device to the recipient's device — over Bluetooth LE, WiFi Direct, or peer-to-peer TCP (optionally via Tor/Orbot). No message ever passes through a server operated by SophaxChat or anyone else.

## Permissions used

| Permission | Why |
|---|---|
| Bluetooth | Discover nearby users and relay messages without internet |
| Local Network | Discover nearby users over WiFi |
| Camera | Take and send encrypted photos |
| Microphone | Record encrypted voice messages |
| Photo Library | Send images from your library |
| Face ID / Touch ID | Unlock the app when App Lock is enabled |

No permission is used for tracking, analytics, or any purpose beyond what is listed above.

## Third-party SDKs

None. SophaxChat has zero third-party dependencies. It uses only Apple's own system frameworks (CryptoKit, MultipeerConnectivity, Network.framework, AVFoundation, LocalAuthentication).

## Open source

SophaxChat is fully open source. You can verify every claim in this policy by reading the source code:

**[github.com/sophaxtechnologies/SophaxChat](https://github.com/sophaxtechnologies/SophaxChat)**

## Changes to this policy

If this policy changes in any way that reduces your privacy, it will be announced prominently in the repository and in the app. Any such change would be contrary to the project's core philosophy and would represent a betrayal of user trust.

## Contact

Security vulnerabilities: [GitHub Security Advisories](https://github.com/sophaxtechnologies/SophaxChat/security/advisories/new)

General questions: [GitHub Issues](https://github.com/sophaxtechnologies/SophaxChat/issues)
