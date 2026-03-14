# Public Release Checklist

*SophaxChat — what needs to happen before a public v1.0 release.*

---

## 🔴 Blockers (must fix before public release)

### Security

- [x] **H-1: Group re-keying on member leave** ✅
  Fixed: `leaveGroup()` broadcasts `groupMemberLeft` before deleting local key material. Remaining members rotate to a fresh random sender chain and redistribute it via their individual DR channels. Departed member loses forward access.

- [x] **Notification content hiding (M-4)** ✅
  Fixed: `UNNotificationCategory("SOPHAX_MSG")` registered in `requestNotificationPermission()` with `hiddenPreviewsBodyPlaceholder = "New message"`. iOS hides body when user sets Show Previews to "When Unlocked" or "Never".

- [x] **Key rotation UI / warning on key change** ✅
  Fixed: TOFU detection in `didDiscoverPeer` — if a peer's `signingKeyPublic` changes and they were never verified, the old safety number is injected into `verifiedPeers` so `hasKeyChanged()` fires the "Safety Number changed" red banner on next open.

### Stability

- [x] **Error handling in ChatManager send paths** ✅
  Fixed: `sendGroupMessage` / `sendGroupAttachment` now store the message as `.sending` first, surface any encryption failure via `didEncounterError` (shown as a red `!` bubble + alert), and mark the stored message `.failed` so the UI reflects the real state.

- [x] **Session state corruption recovery** ✅
  Fixed: `withSession()` catches `importState` failure, deletes the corrupt Keychain blob, and throws `sessionStateCorrupted`. Outbound callers (`sendMessage`, `sendAttachment`) catch this, mark the message `.failed`, and call `broadcastHello()` so the peer re-initiates X3DH. Inbound path also calls `broadcastHello()` on corruption so the peer re-initiates automatically.

- [x] **Group skipped message key cache (M-1)** ✅
  Fixed: `skippedGroupMessageKeys[groupID/senderPeerID][iteration]` bounded cache (200 keys/sender). Out-of-order messages hit the cache first; keys consumed on use (no replay). Evicted automatically when capacity is exceeded.

### App Store / Distribution

- [x] **Privacy manifest (`PrivacyInfo.xcprivacy`)** ✅
  Added: `NSPrivacyTracking=false`, no tracking domains, no collected data types, UserDefaults access declared with reason `CA92.1` (read/write by same app only).

- [ ] **App Store metadata**
  App name, subtitle, description, keywords, screenshots (iPhone 6.7", iPad 12.9"), support URL, privacy policy URL. None of these exist yet.

- [ ] **Privacy policy**
  Required by Apple and GDPR. Minimum content: what data is collected (answer: none stored on servers — none exist), how identity keys are generated, what "disappearing messages" means, contact for data requests. Must be hosted at a public URL.

- [ ] **TestFlight beta program**
  Run a closed beta before public release. Gather crash reports, test edge cases in real-world mesh environments (noisy BLE, mixed iOS/macOS peers).

---

## 🟡 Important (should fix for v1.0)

### Security

- [ ] **Safety Number pinning persistence**
  The app lets users verify Safety Numbers via QR scan, but does not persist the "verified" state. After re-launching the app, verification is lost. Store a flag (keyed by peerID + key fingerprint) in UserDefaults or Keychain.

- [ ] **Sender Key Distribution delivery confirmation (M-2)**
  In high-traffic scenarios, a new group member's first messages may arrive before their SKD is received by peers. Implement a hold-and-retry or buffering mechanism, or include the chain state in a resent SKD.

- [ ] **One-time prekey exhaustion UI (M-3)**
  If Bob's OTPK pool is empty, X3DH proceeds without DH4, reducing entropy. The UI should warn Alice that the session was established without a one-time prekey.

- [ ] **Message ordering in groups (L-2)**
  Group message timestamps are sender-controlled. A malicious or clock-skewed sender can reorder the conversation UI. Consider using a locally-received-at timestamp for display ordering, with the sender timestamp shown as metadata.

### UX / Completeness

- [x] **Offline store-and-forward** ✅
  Fixed: When a relay peer is the only path to the target, the sealed message is also broadcast as a `StoreAndForwardRequest`. Relay peers cache up to 300 items with a 48-hour TTL and deliver them in a batch (`StoreAndForwardDelivery`) when the target peer next connects (triggered from `handleHello`).

- [ ] **Group reply and reactions**
  Currently reply-to and emoji reactions are 1:1 only. Group conversations are missing these features.

- [ ] **Message delivery status in groups**
  There is no "delivered to all members" or "read by N members" indication in group conversations.

- [ ] **Peer reconnect notification**
  No indication when a previously offline peer comes back online (relevant for draining the offline queue).

- [ ] **Username change**
  Once set, the username cannot be changed without wiping the app. Add a rename flow that re-broadcasts the new name to all active sessions.

- [ ] **Localization**
  The app ships English only. At minimum, support the most common languages in the target user base (activists, journalists in non-English regions).

### Code Quality

- [ ] **L-3: `ISO8601DateFormatter` allocation per `signingBytes()` call**
  Minor performance issue. Cache the formatter as a static or injected dependency.

- [ ] **Swift 6 strict concurrency warnings**
  Audit all `@unchecked Sendable` conformances (`ChatManager`, `DoubleRatchet`). Document or enforce the caller-must-serialize contract.

- [ ] **Unit test coverage for group Sender Keys**
  No automated tests for `senderKeyRatchetStep`, `handleGroupMessage` v2 path, or `handleSenderKeyDistribution`. Add tests before the group messaging code ossifies.

- [ ] **Unit tests for sealed sender and header encryption**
  The DR+HE and sealed sender wrappers lack automated tests for round-trip correctness and AAD binding.

---

## 🟢 Nice to have (post v1.0)

- [x] **Background operation** ✅ — `bluetooth-central`/`bluetooth-peripheral` modes + `BGAppRefreshTask` for periodic mesh restart. MPC stays alive minutes after backgrounding; BGTask extends coverage after full suspension.
- [x] **Channel discovery** ✅ — `ChannelAnnouncement` wire type; creators broadcast signed announcements; non-members see "Nearby Channels" in the list.
- [x] **Pluggable transport adapter** ✅ — `MessageTransport` protocol defined; `MeshManager` is the reference implementation; LoRa/audio stubs documented.
- [ ] **Independent third-party security audit** — target NLnet / NGI Zero funding; highest-priority external item
- [ ] **MLS (Messaging Layer Security)** — replace Sender Keys with standards-track group protocol
- [ ] **Hardware security key binding** — FIDO2 / Secure Enclave for identity key protection (SE migration path needed)
- [ ] **iPad-optimized layout** — sidebar + detail view on larger screens
- [ ] **App Clip / Share Extension** — quick-reply without opening the full app

---

## Summary

| Category | Total | Done | Remaining |
|---|---|---|---|
| 🔴 Blockers | 7 | 6 (H-1, M-1, M-4, PrivacyInfo, key-change, send-errors, session-recovery) | 3 (App Store metadata, privacy policy, TestFlight) |
| 🟡 Important | 10 | 1 (store-and-forward) | 9 |
| 🟢 Nice to have | 8 | 3 (background, channels, transport) | 5 |

**Remaining blockers before App Store submission**: App Store metadata (screenshots, description, keywords), privacy policy hosted at a public URL, and TestFlight beta run. No further code blockers.
