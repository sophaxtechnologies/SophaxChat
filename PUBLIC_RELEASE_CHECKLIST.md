# Public Release Checklist

*SophaxChat — what needs to happen before a public v1.0 release.*

---

## 🔴 Blockers (must fix before public release)

### Security

- [ ] **H-1: Group re-keying on member leave**
  Highest-priority security gap. A member who leaves (or is removed) retains all historical sender key chain states and can decrypt any future group traffic they capture. All remaining members must generate fresh sender chains and redistribute them on every membership change. Without this fix, group forward secrecy is meaningless after member churn.

- [ ] **Notification content hiding (M-4)**
  `UNNotificationContent` previews are shown on the lock screen by default, exposing plaintext message content before the user authenticates. Set `hiddenPreviewsBodyPlaceholder` and replace body with a generic placeholder. This is a one-line fix with significant privacy impact.

- [ ] **Key rotation UI / warning on key change**
  If a peer's identity key changes (device wipe, reinstall), the app should warn the user with a prominent "Safety Number changed" banner — like Signal does — rather than silently trusting the new key. Without this, re-installation silently re-establishes trust without user awareness.

### Stability

- [ ] **Error handling in ChatManager send paths**
  Several `sendGroupMessage` / `sendGroupAttachment` code paths return silently on encryption failure. The UI never surfaces these errors; messages appear to send but are silently dropped. Failed sends must surface to the user.

- [ ] **Session state corruption recovery**
  If the Keychain contains a malformed or truncated Double Ratchet session blob (e.g., after a crash mid-write), the app currently fails to load the session and cannot decrypt any further messages. A session reset / re-initiation path is needed.

- [ ] **Group skipped message key cache (M-1)**
  Out-of-order group messages beyond the MAX_SKIP=100 window are silently dropped and irrecoverable. The fix is caching intermediate message keys in a bounded table (same approach as the DR layer).

### App Store / Distribution

- [ ] **Privacy manifest (`PrivacyInfo.xcprivacy`)**
  Required by Apple for all apps submitted to the App Store since Spring 2024. Must declare: no third-party SDKs with required reasons, no API usage that requires a reason (check for `UserDefaults`, `FileManager`, `NSFileProtection`, etc.). Currently missing.

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

- [ ] **Offline store-and-forward**
  Currently, if Alice sends a message to Bob and Bob is not reachable via the mesh (not even via relay through a common peer), the message is queued in memory and lost on app restart. A persistent offline queue (stored to disk, replayed on peer reconnect) would significantly improve reliability.

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

- [ ] **Background operation** — BLE peripheral mode to receive messages when app is backgrounded (PushKit or background fetch fallback)
- [ ] **LoRa / audio covert channel transport adapter** — pluggable transport layer for extreme scenarios
- [ ] **Independent third-party security audit** — target NLnet / NGI Zero funding
- [ ] **MLS (Messaging Layer Security)** — replace Sender Keys with a standards-track group protocol that also handles member change re-keying (H-1) automatically
- [ ] **Hardware security key binding** — FIDO2 / Secure Enclave for identity key protection
- [ ] **Channel discovery** — broadcast group announcements on the mesh
- [ ] **iPad-optimized layout** — sidebar + detail view on larger screens
- [ ] **App Clip / Share Extension** — quick-reply without opening the full app

---

## Summary

| Category | Count | Status |
|---|---|---|
| 🔴 Blockers | 7 | Must fix |
| 🟡 Important | 10 | Should fix |
| 🟢 Nice to have | 8 | Post v1.0 |

**Minimum viable public release**: fix all 🔴 blockers. Estimated effort: 2–3 weeks of focused engineering + App Store review cycle.
