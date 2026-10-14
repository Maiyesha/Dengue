# iOS Offline Storage, Background Upload and Security for DengueSense Capture App

Scope: an offline-first data layer and security design for a clinician-supervised, Research-Use-Only iOS capture app that records per-step biometric video (no audio, study ID only, no PHI). Current as of Oct 2026 (iOS 18 / iOS 26).

Source note: developer.apple.com doc pages render with JavaScript and could not be fetched as text. Where an Apple doc is named but not quoted, the claim comes from a secondary source or from Apple pages indexed in search results. These are flagged. Apple Platform Security (support.apple.com) pages were fetched directly.

---

## 1. Data Protection classes, encryption at rest, Keychain, backup exclusion, secure deletion

### Takeaway
Use **NSFileProtectionCompleteUnlessOpen (Class B)** for in-progress capture files. The camera writer can keep the file open and writing if the device locks mid-capture, and the file key is wiped once the file is closed. Background URLSession reads the file out-of-process while the device may be locked, so the upload copy (the sealed, already-encrypted artefact) generally needs **CompleteUntilFirstUserAuthentication (Class C)**. Add an app-layer AES-GCM envelope whose key comes from a Secure Enclave P-256 key agreement, so the ciphertext sitting at Class C is still bound to hardware. Store tokens and keys as `ThisDeviceOnly` Keychain items, exclude artefacts from backup, and rely on crypto-erase (destroying the key) rather than overwriting files.

### Cited Findings
- **Class A (Complete):** "the decrypted class key is discarded" shortly after lock, so data is inaccessible until unlock. The key is derived from the passcode plus device UID. — [Apple Platform Security: Data Protection classes](https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web)
- **Class B (CompleteUnlessOpen):** files can be *created and written while locked*. The per-file key is wrapped with One-Pass ECDH over Curve25519 (NIST SP 800-56A), and the ephemeral public key is stored with the wrapped key. "As soon as the file is closed, the per-file key is wiped from memory." Reopening needs the class private key, which is available only when unlocked. — [Apple Platform Security](https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web)
- **Class C (CompleteUntilFirstUserAuthentication):** like Class A, except "the decrypted class key isn't removed from memory when the device is locked". It protects against reboot-based attacks. "This is the default class for all third-party app data not otherwise assigned." — [Apple Platform Security](https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web)
- **Class D (None):** protected only by the UID in Effaceable Storage, so its main benefit is fast wipe. — [Apple Platform Security](https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web)
- **Per-file keys:** each new file on the data volume gets a 256-bit per-file key, which the hardware AES Engine uses as data is written to flash. Effaceable Storage is a directly addressable NAND area for keys that "can be wiped securely" and supports fast wipe and forward security. — [Apple Platform Security: Effaceable Storage](https://support.apple.com/guide/security/aside/sec0183122de/web); [Apple Platform Security PDF index](https://support.apple.com/en-in/guide/security-pdf/secf6276da8a/web)
- **Wear leveling:** overwriting flash gives no guarantee of erasure, which is why key erasure (crypto-shredding) is the meaningful primitive. This comes from an informal 2012 Apple mailing-list post. — [Apple fed-talk list, 2012](https://lists.apple.com/archives/fed-talk/2012/Sep/msg00116.html). Whether deleting a single file immediately destroys its per-file key was asked on the same list and not answered definitively. — [fed-talk 2014](https://lists.apple.com/archives/fed-talk/2014/Dec/msg00012.html)
- **Secure Enclave in CryptoKit:** it supports only P-256 signing (`SecureEnclave.P256.Signing`) and key agreement (`SecureEnclave.P256.KeyAgreement`). It has no symmetric or AES API. The correct pattern is SE ECDH, then HKDF to a `SymmetricKey`, then software AES-GCM (or `AES.KeyWrap`, RFC 3394, to wrap a per-file data key). — [community CryptoKit/SE reference (tessl)](https://tessl.io/registry/dpearson2699/swift-ios-skills/3.9.0/files/skills/swift-security/references/secure-enclave.md) (secondary; verify against Apple CryptoKit docs)
- **Keychain accessibility:** `...ThisDeviceOnly` items are excluded from backups and device-to-device migration. The `AfterFirstUnlock` family stays readable while locked after the first unlock, so it suits background work. — [keychain access-control reference (tessl)](https://tessl.io/registry/dpearson2699/swift-ios-skills/3.6.1/files/skills/swift-security/references/keychain-access-control.md); [Firefox iOS source comments](https://searchfox.org/mozilla-mobile/source/firefox-ios/MozillaRustComponents/Sources/MozillaRustComponentsWrapper/FxAClient/FxAKeychain/FxAKeychainItemAccessibility.swift)
- **Field report:** a developer saw intermittent `errSecInteractionNotAllowed (-25308)` on background Keychain reads even with `AfterFirstUnlock(ThisDeviceOnly)`. — [Apple Developer Forums 809534](https://developer.apple.com/forums/thread/809534)

### Inferences
- **Recommended per-artefact lifecycle:**
  1. AVAssetWriter writes `step_N.mov` (video only, no audio track) into `Application Support/Artefacts/` with **Class B**, so locking mid-capture does not break the write.
  2. On finish, run the on-device quality model.
  3. On ACCEPT, seal the file into an AES-GCM envelope (`.dsx`) using a random per-artefact data key (DEK). Wrap the DEK with a key-encryption key (KEK) derived via HKDF from `SecureEnclave.P256.KeyAgreement` against a server public key or an app key, and record the SHA-256 of the plaintext and the ciphertext.
  4. Write the sealed file with **Class C** so `nsurlsessiond` can stream it while locked.
  5. Delete the Class B plaintext.
  6. On REJECT, delete immediately and record the event in the audit outbox.
- **Practical caveat on streaming:** AES-GCM needs the whole message for one tag, so a 300 MB file means either chunked AEAD (for example 4 MB segments, each with its own nonce and tag, in the style of STREAM or age) or reading the file in memory-mapped form. Chunking also lines up with multipart part boundaries.
- **Server encryption:** if the server must decrypt, wrap the DEK to a server-held public key (HPKE, available in CryptoKit from iOS 17) and upload the wrapped DEK as metadata. The device then cannot decrypt after sealing, which strengthens the "no PHI on device" stance.
- **Backup exclusion:** set `URLResourceValues.isExcludedFromBackup = true` on the artefact directory and the database, and store artefacts under Application Support (not Documents, so not visible in Files). This API is well known but was not fetched here; verify on developer.apple.com.
- **Secure delete:** delete the file *and* destroy the DEK record. With chunked envelope encryption, crypto-shredding the DEK is the only reliable "delete" on flash. Log `artefact_deleted` with the hash to the audit trail.
- **Keychain items:** refresh token, App Attest keyId and SE key references should use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the background upload handler can mint URLs while locked. A shared access group is needed only if an extension (for example a Broadcast or SSO extension) needs them. Wrap reads in retry logic for -25308.

### Gaps
- Could not fetch Apple's `isExcludedFromBackup`, `FileProtectionType` or Keychain `kSecAttrAccessible*` pages (JS-rendered). The Keychain points rest on secondary sources.
- No primary Apple statement found that per-file key deletion on unlink is immediate.
- No confirmation found on whether nsurlsessiond can read **Class B** files while locked after they are closed. The class semantics imply not (reopening needs unlock), hence the Class C recommendation. Test on a device.

---

## 2. Background URLSession uploads, BGTaskScheduler, large files, pre-signed URL expiry, resumable uploads

### Takeaway
Use a **background URLSession with `uploadTask(with:fromFile:)` only** (no data or stream bodies), recreate it at launch, and handle `handleEventsForBackgroundURLSession`. For files of hundreds of MB, use **S3 multipart upload with one pre-signed URL per part (5 MiB to 5 GiB parts)**. Mint part URLs lazily, close to when each part starts, because the 900 s expiry is checked at request start. iOS 26 adds `BGContinuedProcessingTask` for user-initiated work with system progress UI. Use it for preparing and sealing artefacts, not as a replacement for background URLSession transfers.

### Cited Findings
- Background sessions in summary: uploads only from file; a delegate is required; transfers run in a system daemon; the app is relaunched in the background when transfers complete if it was terminated by the system; on user force-quit the system cancels tasks and does not relaunch. Recreate the session with the same identifier at launch, store the completion handler from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`, and call it from `urlSessionDidFinishEvents`. `isDiscretionary = true` lets the system defer to Wi-Fi or power. — summarised from [Apple: URLSessionConfiguration.background(withIdentifier:)](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)) (page body not retrievable; content from fetch tool's background knowledge, needs verification)
- **Force quit (Quinn, Apple DTS):** "In iOS 8 and later, the session persists but all its tasks are cancelled". Check `NSURLErrorBackgroundTaskCancelledReasonKey`. Test on a real device, not the Simulator, launched from the Home screen (the Xcode debugger prevents suspension). Simulate a system kill with `exit()`, not a force quit. — [Apple Developer Forums: Testing Background Session Code](https://developer.apple.com/forums/thread/14855)
- **S3 multipart limits:** max object 5 TiB; up to 10,000 parts; part size 5 MiB to 5 GiB; no minimum for the last part. — [AWS S3 multipart upload limits](https://docs.aws.amazon.com/us_en/AmazonS3/latest/userguide/qfacts.html)
- **Pre-signed expiry:** S3 checks the expiration "at the time of the HTTP request". A transfer that started before expiry can complete after it, but a retry after expiry fails. If the URL was signed with temporary credentials, it expires when those credentials expire, even if the stated expiry is later. — [AWS: Download and upload objects with presigned URLs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url); [S3 on Outposts presigned URL](https://docs.amazonaws.cn/en_us/AmazonS3/latest/s3-outposts/S3OutpostsPresignedURL.html)
- **BGContinuedProcessingTask (iOS 26+, WWDC25 session 227):** for continuing **user-initiated** work after backgrounding, with system progress UI (`task.progress`, expiration handler, `setTaskCompleted`). It is registered dynamically when the user starts the action, not at launch, and is not intended for automatic sync or maintenance. — [WWDC25 session 227](https://developer.apple.com/la/videos/play/wwdc2025/227/); [DEV Community summary](https://dev.to/arshtechpro/wwdc-2025-ios-26-background-apis-explained-bgcontinuedprocessingtask-changes-everything-9b5) (secondary). A wildcard identifier suffix in `BGTaskSchedulerPermittedIdentifiers` on iOS 26 is reported only by third-party guides and is unverified.

### Inferences
- **Upload pipeline:**
  1. The outbox row moves from `ACCEPTED` to `SEALED`.
  2. Call `POST /uploads` with an Idempotency-Key. The server returns `uploadId`, part size, and URLs for the first k parts. Each URL is valid for 900 s, so request URLs only for parts that are about to start.
  3. Pre-split the sealed file into **part files** (8 to 16 MiB each) on disk, because background sessions need a file per task.
  4. Enqueue one background `uploadTask(fromFile:)` per part, limiting concurrency to 2 to 4.
  5. On each part's completion, record the ETag in the outbox.
  6. On HTTP 403 `AccessDenied` / `Request has expired`, mark the part `NEEDS_URL`, re-mint the URL with the same idempotency scope, and re-enqueue.
  7. When all parts are complete, call `POST /uploads/{id}/complete` with the ETag list and the Idempotency-Key.
- **Background constraint:** in the background, the app gets only short wakes when tasks complete. Re-minting a URL then needs a network call from inside that wake, so the server must accept refresh-token or assertion use from background wakes. Alternatively, mint a batch of part URLs up front and accept that some will expire. Because expiry is checked at request start, a single 300 MB PUT that starts within 900 s will finish, but any retry needs a new URL.
- **Single PUT vs multipart:** single-PUT S3 allows up to 5 GB, but a failed 300 MB PUT restarts from zero. Multipart parts give natural resumability. tus is an alternative if the backend is not S3-compatible. Since data must stay in Malaysia, the object store will likely be AWS ap-southeast-5 (Malaysia) or a local S3-compatible store. Check that the provider supports pre-signed UploadPart.
- **Discretionary setting:** set `isDiscretionary = false` for clinical uploads (the user expects timeliness). Optionally use a second discretionary session for bulk backfill. Set `timeoutIntervalForResource` (default 7 days) to match the study's retention or upload SLA.
- **Integrity:** send `Content-MD5` or `x-amz-checksum-sha256` per part (this must be included when the URL is signed) so the server can verify integrity.
- **BGProcessingTask:** use it only for housekeeping, such as purging uploaded artefacts or compacting the database. It runs at system discretion, typically while charging and idle, so do not rely on it for upload SLAs.

### Gaps
- Could not retrieve Apple's text on background session resume-rate limiting (the system delays relaunches when an app repeatedly wakes). Treat it as a known issue to test.
- No AWS doc found that explicitly confirms per-part pre-signed UploadPart semantics. It follows from SigV4 query auth, but the server team should validate it.

---

## 3. Offline durable outbox, idempotency, conflicts, clock skew, feature_availability_timestamp

### Takeaway
Use a **SQLite outbox (GRDB recommended)** as the single source of truth, with the database file protected at Class C and excluded from backup. Each mutating intent gets a UUID v4 Idempotency-Key that is **generated once and persisted with the row**, so retries after crashes or relaunches reuse it. Capture timestamps with both wall-clock time and monotonic uptime plus a server-time offset. Record `feature_availability_timestamp` as when the artefact became locally available (quality ACCEPT time), separately from upload or server-receipt time.

### Cited Findings
- `systemUptime` and `mach_absolute_time` fall under the **SystemBootTime** required-reason category. Reason 35F9.1 covers measuring elapsed time between in-app events. Reading file timestamps (C617.1, app-container files) and disk space (E174.1, checking space before writes) also need declared reasons. UserDefaults is also a required-reason API (CA92.1 = app-only access). — [Nutrient: Privacy manifests and required reason APIs](https://www.nutrient.io/blog/privacy-manifests-on-ios/); [Bugfender](https://bugfender.com/blog/apple-privacy-requirements/) (secondary; reason codes should be confirmed against Apple's "Describing use of required reason API")

### Inferences
- **Schema sketch (GRDB):**
  - `capture_session(id, study_id, device_id, started_wall, started_uptime_ns, server_offset_ms)`
  - `artefact(id, session_id, step, path, sha256, size, quality_result, quality_model_version, feature_availability_ts_wall, feature_availability_uptime_ns, state)`
  - `outbox(id, idempotency_key UUID UNIQUE, kind, payload_json, attempt, next_attempt_at, state, last_error, created_at)`
  - `upload_part(artefact_id, part_no, path, etag, state)`
  - `audit_event(id, kind, artefact_id, actor, ts_wall, ts_uptime, hash_prev, hash_self)` (hash-chained for tamper evidence; mirrored to server)
- **Why GRDB or SQLite over SwiftData or Core Data:** explicit transactions, WAL mode, deterministic migrations, and easy setting of file protection on the `.sqlite`, `-wal` and `-shm` files. Core Data can do the same. SwiftData (iOS 17+) has less control over the underlying store and file protection. This is an opinion; no benchmark was sourced.
- **Idempotency:** the server dedupes on (key, principal, route) for 24 h and returns the original response. The client must not regenerate the key on retry. If a row has been pending for more than 24 h, the server will treat a retry as new, so make the server operation natural-key idempotent as well (for example on `artefact_id` and `sha256`) to survive the window expiring.
- **Conflict handling:** captures are append-only and immutable, with artefact IDs generated on the client (UUIDv4 or UUIDv7). The only conflicts are on deletion or withdrawal versus upload completion. Resolve them on the server with "delete wins" plus tombstones that are synced down.
- **Clock skew:** on each authenticated response, compute `server_offset = Date header − local wall` (or use a `/time` endpoint) and store it with the session. Store raw device wall time, uptime, the offset and a timezone. The server computes `corrected_ts` and flags skew above a threshold (for example 120 s). Uptime resets on reboot, so also store a boot session ID.
- **feature_availability_timestamp:** set it at quality ACCEPT (when the artefact became eligible for analysis). Upload-complete and server-ingest times are separate. This supports latency metrics and research-use provenance.

### Gaps
- No authoritative source retrieved comparing GRDB, Core Data and SwiftData durability. The recommendation is engineering judgement.
- The exact semantics of "feature_availability_timestamp" in the project specs were not available to this researcher. The interpretation above is an assumption.

---

## 4. App Attest, DeviceCheck, jailbreak detection

### Takeaway
**App Attest** gives a hardware-backed (Secure Enclave) key per *install*. Attest it once, then sign per-request assertions with server challenges and a monotonic counter. The "renew every 24 h" requirement should be implemented as a **fresh server-challenged assertion (or re-attestation only when needed) every 24 h** that refreshes a short-lived device-trust token. Re-calling `attestKey` daily is the wrong approach given Apple's rate limits. It is unavailable on the Simulator. Jailbreak detection is defence-in-depth only.

### Cited Findings
- **Rate limits:** Apple's "Preparing to use the App Attest service" guidance says to keep `attestKey` calls under about 100 requests per second across all installs, notes that the threshold "may fluctuate dynamically", and says to ramp up no more than 10M users per day. An Apple DTS engineer advises keeping it in double digits per second with about one attestKey per installation. — [Apple: Preparing to use the App Attest service](https://developer.apple.com/documentation/devicecheck/preparing-to-use-the-app-attest-service.md); [Apple Developer Forums thread 759285](https://developer.apple.com/forums/thread/759285); [thread 778937](https://developer.apple.com/forums/thread/778937)
- **Flow:**
  1. Check `isSupported` (false on the Simulator).
  2. Call `generateKey()` once per install and store the `keyId`.
  3. The server issues a challenge.
  4. Call `attestKey(keyId, clientDataHash: SHA256(challenge))`.
  5. The server validates the chain to the Apple App Attest Root CA, checks nonce = SHA256(authData‖clientDataHash), checks that keyId = SHA256(pubkey) and rpIdHash = SHA256(TeamID.BundleID), checks the environment (dev or prod via the `com.apple.developer.devicecheck.appattest-environment` entitlement), and stores the pubkey, counter and receipt.
  6. Later requests call `generateAssertion(keyId, clientDataHash)`, and the server checks the signature and that the counter strictly increases.
  7. Receipts can be exchanged with Apple for a fraud risk metric.
  
  — [Apple: Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server) (page not retrievable as text; steps summarised by fetch tool from background knowledge and consistent with [Approov App Attest docs](https://docs.approov.io/app-integration/apple-appattest); verify)
- **Rollout:** Firebase recommends a gradual rollout via Remote Config to avoid attestation throttling. — [Firebase codelab](https://firebase.google.com/codelabs/app-attest-remote-config)
- **Jailbreak detection:** MASTG says common checks are bypassed most quickly with objection, and harder ones with Frida early instrumentation. Automated bypass tests "may not detect all" checks. Frida can be detected via frida-server or an injected agent, and implicitly through runtime integrity checks. — [MASTG-KNOW-0087](https://mas.owasp.org/MASTG/knowledge/ios/MASVS-RESILIENCE/MASTG-KNOW-0087/); [MASTG-TEST-0241](https://mas.owasp.org/MASTG/tests/ios/MASVS-RESILIENCE/MASTG-TEST-0241/); [MASTG-TEST-0240](https://mas.owasp.org/MASTG/tests/ios/MASVS-RESILIENCE/MASTG-TEST-0240/)
- Jailbreak detection is defence in depth, because "the attacker controls the environment". — [SecureLayer7 guide](https://securelayer7.net/learn-pdf/mobile-security/root-jailbreak-detection-bypass.pdf)

### Inferences
- **Device fingerprint binding:** bind the refresh token to the App Attest `keyId` (a hardware key that cannot be exported) rather than to a soft fingerprint (identifierForVendor, model). At refresh, the client sends an assertion over (refresh_token_hash ‖ server_nonce). The server rotates the token, invalidates the old one, and treats reuse as theft, revoking the family. Note: `generateAssertion` is an online, challenge-based call, so background URL re-minting needs either a nonce that can be fetched in the same wake, or a pre-issued nonce.
- **24 h renewal:** issue a "device attestation token" with a 24 h TTL after a successful assertion and optionally a risk-metric check. When it expires, require a fresh assertion. Re-run `attestKey` only after a reinstall, a keyId invalidation (`DCError.invalidKey`) or a server policy reset.
- **Fallbacks:** the Simulator and dev builds need a server-side bypass gated by environment. **DeviceCheck** (2 bits per device plus a timestamp) can flag a device as revoked across reinstalls, for example a lost ward iPad.
- **Monitoring:** use App Attest risk-metric spikes plus MDM compliance (supervised, managed) as the main integrity signals. Jailbreak heuristics are only a telemetry signal and should not hard-block, given false positives on clinical devices.

### Gaps
- Apple's exact rate-limit text and receipt or risk-metric endpoint details could not be fetched from primary pages.
- No public statement found on whether App Attest keys survive device restore or migration (expected: they do not).

---

## 5. Clinician authentication: passkeys/WebAuthn, enterprise SSO, shared ward iPads, session timeouts

### Takeaway
Do OIDC (Authorization Code + PKCE) via **ASWebAuthenticationSession** (AppAuth-iOS is fine), with the hospital IdP doing MFA or passkeys. That way, MDM-deployed **Extensible SSO extensions** (for example Microsoft Enterprise SSO plug-in, Okta) give SSO automatically. Use native `ASAuthorizationPlatformPublicKeyCredentialProvider` only if the app is itself a relying party. On managed devices, MDM **passkey attestation** (from iOS 17) lets the RP verify enterprise-issued passkeys. For ward iPads, prefer **Shared iPad with Managed Apple Accounts or temporary sessions**, or single-app-user mode plus an app-level fast clinician switch with short timeouts.

### Cited Findings
- Passkey registration uses `createCredentialRegistrationRequest` and sign-in uses `createCredentialAssertionRequest` on `ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier:)`. This needs Associated Domains `webcredentials:`. — [Auth0 blog](https://auth0.com/blog/sign-up-log-in-passkeys-ios-using-auth0-native-login.md)
- **Enterprise passkey attestation (WWDC23 "Deploy passkeys at work"):** an MDM declarative configuration (`com.apple.configuration.security.passkey.attestation`) references an identity asset from the corporate CA. The device then attests newly generated passkeys for listed relying parties. Available on iOS, iPadOS and macOS 17+. — [WWDC Notes: Deploy passkeys at work](https://wwdcnotes.com/notes/wwdc23/10263) (third-party transcription)
- Consumer iCloud Keychain passkeys provide no attestation and a zeroed AAGUID. — [Corbado: iOS 26 passkeys](https://www.corbado.com/blog/ios-26-passkeys) (vendor blog)
- **Microsoft Enterprise SSO plug-in:** an Apple Extensible SSO (Redirect type) extension in Microsoft Authenticator, with extension ID `com.microsoft.azureauthenticator.ssoextension`. It covers non-MSAL apps using OAuth 2, OIDC and SAML, is enabled by any MDM, and works with device and user enrollment. IdP URLs must be excluded from TLS interception. — [Microsoft Learn: Enterprise SSO plug-in for Apple devices](https://learn.microsoft.com/entra/identity-platform/apple-sso-plugin)
- ASWebAuthenticationSession benefits from SSO extensions automatically. The extension must be installed before use. — [Apple Developer Forums 830480](https://developer.apple.com/forums/thread/830480) (forum opinion)
- **Shared iPad quotas:** on 32 GB devices, 10 GB system + 8 GB apps, with at least 1 GB per user. On devices of 64 GB and above, 10 GB system + 16 GB apps, with at least 2 GB per user. The oldest user's local data is evicted when space is needed. — [Apple Deployment: Shared iPad](https://support.apple.com/guide/deployment/dep6fa9dd532)
- **Temporary sessions (iPadOS 13.4+):** at sign-out, the user's APFS volume is deleted. Users whose data has synced can be evicted. — [Apple Platform Security: Shared iPad](https://support.apple.com/guide/security/secd99f373ef); [Cisco Meraki docs](https://documentation.meraki.com/SM/Deployment_Guides/Apple_Shared_Device_Mode_and_Guest_Temporary_Sessions)

### Inferences
- **Shared iPad risk:** pending uploads stored in a clinician's user volume could be **evicted or destroyed at sign-out** (temporary session) before upload completes. Two options follow:
  - (a) Use **single-user supervised devices** where the app is the trust boundary (device identity = App Attest + MDM). Clinicians switch inside the app with SSO plus a passkey, or a short re-auth with a PIN or biometrics, while the device-level outbox survives clinician switches.
  - (b) On Shared iPad, block sign-out until the outbox is drained, which is not enforceable.
  
  Option (a) is likely simpler for ward workflows. The artefact store should then be keyed to the device and study, not the user, and the clinician identity recorded per audit event.
- **Session policy:** access JWT 15 min. Refresh tokens are single-use and bound to the App Attest key. Use an idle UI lock (for example 2 to 5 min, configurable via Managed App Config) that requires a LocalAuthentication or passkey re-assertion, and an absolute session maximum (for example 12 h, one shift). Background uploads should run under a **device-scoped upload credential**, not the clinician's session, so a clinician logout does not stall uploads. The audit trail still records which clinician captured the data.
- **Managed App Configuration** (`UserDefaults` key `com.apple.configuration.managed`): use it to push the IdP issuer, client ID, Malaysia API base URL, timeouts and the feature flags for the attestation rollout. Report status back via `com.apple.feedback.managed`. (Standard MDM mechanism; not fetched in this session.)

### Gaps
- No Apple primary doc retrieved for iOS 26 changes to passkey MDM payloads or Shared iPad (for example any changes to Return to Service).
- AppAuth-iOS specifics (maintenance status in 2026) were not verified.

---

## 6. Certificate pinning (NSPinnedDomains) pros and cons

### Takeaway
`NSPinnedDomains` (Info.plist ATS identity pinning, iOS 14+) is a low-code, declarative SPKI-hash pin that applies to URLSession, including background sessions. Pin **CA or intermediate SPKIs plus a backup**, not leaf certificates, and exclude the pre-signed object-storage host unless you control its CA. It does not protect against a repackaged app and offers no user override.

### Cited Findings
- `NSPinnedDomains` → per domain `NSPinnedCAIdentities` / `NSPinnedLeafIdentities`, each `SPKI-SHA256-BASE64`, with an optional `NSIncludesSubdomains`. Apple's built-in mechanism for URL Loading System connections. — [OWASP MASTG-KNOW-0072](https://mas.owasp.org/MASTG/knowledge/ios/MASVS-NETWORK/MASTG-KNOW-0072/); [MASTG-TEST-0385](https://mas.owasp.org/MASTG/tests/ios/MASVS-NETWORK/MASTG-TEST-0385/)
- Risks: a missing backup pin or a key rotation without updating pins breaks connectivity. Pins can be stripped by re-signing a modified app. — [OWASP MASTG-TEST-0385](https://mas.owasp.org/MASTG/tests/ios/MASVS-NETWORK/MASTG-TEST-0385/); [Guardsquare](https://www.guardsquare.com/blog/leveraging-infoplist-based-certificate-pinning-ios-and-making-its-shortcomings)
- One developer reported inconsistent `NSIncludesSubdomains` coverage. — [Apple Forums 705162](https://developer.apple.com/forums/thread/705162)
- An ATS pin failure has no user override. — [Apple Forums 731368](https://developer.apple.com/forums/thread/731368)

### Inferences
- **Pros:** works in background sessions with no delegate code (custom `didReceive challenge` pinning also works, but needs the app awake), it is declarative, and it is auditable.
- **Cons:** pins are frozen per app build, so rotation needs an app update (MDM can push updates quickly to managed devices, which mitigates this). Pinning an AWS S3 endpoint is fragile because AWS controls its CAs.
- **Recommendation:** pin the API, auth and attest hosts to the organisation's intermediate CA plus an offline backup key. Don't pin the S3 or object-storage host; protect those uploads with short-lived signed URLs plus payload encryption and checksums.
- **TLS 1.3:** ATS defaults to a minimum of TLS 1.2. Set `NSExceptionMinimumTLSVersion` = `TLSv1.3` per domain (or enforce it on the server).
- **mTLS:** the requirement covers service-to-service traffic. Client certificates on iOS are possible via an MDM-delivered identity (SCEP/ACME) and a URLSession client-certificate challenge, but App Attest-bound tokens usually make device mTLS unnecessary.

### Gaps
- Did not verify whether ATS's TLS 1.3 minimum setting is honoured in background sessions. Expected yes; test it.

---

## 7. Privacy manifest, required reason APIs, camera strings, screenshot/screen-recording protection

### Takeaway
Ship a `PrivacyInfo.xcprivacy` declaring the collected data types (health or biometric video linked to a study ID, not used for tracking) and the required-reason APIs used (UserDefaults, file timestamps, disk space, system boot time). Include `NSCameraUsageDescription` and **no microphone permission**. iOS has **no supported API to block screenshots**. Detect capture with `sceneCaptureState` / `UIScreen.isCaptured` and the screenshot notification, then blur the content and audit the event.

### Cited Findings
- **Required-reason categories and common codes:** UserDefaults (CA92.1), File timestamp (C617.1 container / DDA9.1 display), SystemBootTime (35F9.1 elapsed time), DiskSpace (E174.1 check before writing / 85F4.1 display). — [Nutrient](https://www.nutrient.io/blog/privacy-manifests-on-ios/); [Bugfender](https://bugfender.com/blog/apple-privacy-requirements/); [Unity Apple privacy manifest policy](https://docs-alpha.unity3d.com/cn/2023.2/Manual/apple-privacy-manifest-policy.html) (secondary; confirm with Apple's list)
- **Screenshots:** an Apple engineer states iOS provides no API to prevent screenshots. The secure-text-field overlay trick is outside its intended purpose. For detection, Apple recommends `sceneCaptureState` (covers recording, AirPlay mirroring and remote control). — [Apple Developer Forums 838583](https://developer.apple.com/forums/thread/838583)
- `UIScreen.isCaptured` detects mirroring and recording but not still screenshots. Screenshots can only be detected after the fact (`userDidTakeScreenshotNotification`). The secure-field trick is reported broken in some forms on iOS 26. — [itnext](https://itnext.io/a-way-to-protect-your-app-content-from-screenshots-in-ios-ea23153a3bc7); [B4X forum](https://www.b4x.com/android/forum/threads/prevent-screenshot-ios.170927/)

### Inferences
- **Camera configuration:** use `AVCaptureSession` with video input only and no audio input. Then iOS never prompts for the microphone, and the absence of `NSMicrophoneUsageDescription` documents "no audio". The camera string should state the purpose, for example "Records short guided videos for dengue risk research. Videos are linked only to a study ID."
- **Privacy manifest data types:** declare `NSPrivacyCollectedDataTypeHealth` and/or `...SensitiveInfo` / `...PhotosorVideos` as linked to a pseudonymous ID, with purpose App Functionality, and `NSPrivacyTracking` = false. Third-party SDKs (for example GRDB or AppAuth) must ship their own manifests. RUO clinical research apps are usually distributed privately (ABM Custom Apps or Enterprise), but the manifest still applies to App Store and Custom App review.
- **App switcher snapshot:** on `sceneWillResignActive`, overlay a privacy view so the snapshot does not capture the study ID or preview frames.
- On a capture-state change, pause the preview, show a shield, and log `screen_capture_detected` to the audit trail.

### Gaps
- Apple's authoritative required-reason table was not fetched directly.

---

## 8. MDM deployment for hospital devices

### Takeaway
Deploy via **Apple Business Manager + MDM** as a **Custom App** (private distribution to the organisation) or ABM-assigned VPP licences, on **supervised, ADE-enrolled** iPads and iPhones. Use managed app config, per-app VPN if needed, remote wipe, and "remove app on unenrol" (managed app removal deletes the app's container). Combine this with App Attest and an MDM compliance signal for device trust.

### Cited Findings
- Shared iPad space allocation is configured in the enrollment profile (max users or quota per user). — [Miradore](https://www.miradore.com/knowledge/ios/shared-ipad-for-setting-up-an-ios-device-for-multiple-users/); [Hexnode](https://www.hexnode.com/mobile-device-management/help/ios-shared-device-settings/)
- Extensible SSO profiles must be pushed by MDM. — [Microsoft Learn](https://learn.microsoft.com/entra/identity-platform/apple-sso-plugin)
- Passkey attestation configuration is delivered by MDM. — [WWDC Notes 10263](https://wwdcnotes.com/notes/wwdc23/10263)

### Inferences
- **Device posture:** supervised with ADE (no user un-enrol); passcode policy enforced (which also strengthens Data Protection, since class keys derive from the passcode); iCloud backup and iCloud Drive restricted for managed apps; managed Open-In restrictions to prevent exporting video; Managed App Config for endpoints; Single App Mode or Autonomous Single App Mode for kiosk-like capture stations.
- **Lost device:** use MDM Lost Mode or wipe, DeviceCheck bit flip, server revocation of the App Attest keyId and refresh-token family, and invalidation of outstanding pre-signed URLs (they are short-lived anyway).
- **Data residency:** the MDM vendor, IdP and logging or telemetry SDKs must also be assessed for Malaysian residency. Disable third-party crash or analytics SDKs that ship data offshore, or self-host them.

### Gaps
- Primary Apple Deployment Guide pages on managed app removal, Return to Service and iOS 26 declarative management changes were not fetched in this session (tool-call budget). The claims above in this section are standard MDM practice and are not cited.
- No source checked for Apple Business Manager availability in Malaysia.
