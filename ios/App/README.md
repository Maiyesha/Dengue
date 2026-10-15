# DengueSense iOS app (ios/App)

The app target is generated with XcodeGen (`project.yml`) and built and tested by `.github/workflows/ios.yml`
on macOS. Pure logic lives in the `DengueCaptureCore` package (`ios/DengueCaptureCore`, tested on every platform).
The app sources were written on a Windows host without an Apple toolchain: they are **unverified until the
first macOS CI run**.

## Managed App Configuration (MDM)

| Key | Used for |
|---|---|
| `api_base_url` | DengueAPI base URL (https only). Without it uploads and consent are disabled (capture blocked). |
| `ward_id` | Device enrolment and the offline roster. |
| `oidc_issuer`, `oidc_client_id` | Nurse sign-in (OIDC code + PKCE). |
| `kms_public_key_pem` | Server KMS RSA public key (SubjectPublicKeyInfo PEM, RSA >= 3072 bit). Every artefact data key is wrapped with it (RSA-OAEP-SHA256). Without it hand-offs are held with `KMS_KEY_MISSING`. |
| `kms_key_id` | KMS key id sent with each artefact (`kms_key_id`), used by the server to unwrap. |

## TLS 1.3 and certificate pinning (I7)

- API and OIDC requests use a dedicated ephemeral `URLSession` (`NetworkSecurity`) with
  `tlsMinimumSupportedProtocolVersion = .TLSv13`; `URLSession.shared` is not used for them.
- Pins are declared in Info.plist (`NSAppTransportSecurity` / `NSPinnedDomains`) from build settings:

  | Build setting | Meaning |
  |---|---|
  | `DS_API_HOST` | API host name, e.g. `api.example.org` (no scheme, no path) |
  | `DS_AUTH_HOST` | Identity provider host name |
  | `DS_API_SPKI_SHA256`, `DS_API_SPKI_BACKUP_SHA256` | base64 SHA-256 of the API leaf certificate's SubjectPublicKeyInfo: current key and a pre-generated backup key |
  | `DS_AUTH_SPKI_SHA256`, `DS_AUTH_SPKI_BACKUP_SHA256` | the same for the identity provider |

  Set them in an environment xcconfig or on the CI command line
  (`xcodebuild ... DS_API_HOST=api.example.org DS_API_SPKI_SHA256=...`). The defaults in `project.yml` are
  placeholders on the `.invalid` TLD and must never ship.

  Compute a pin from a certificate:

  ```sh
  openssl x509 -in api.pem -pubkey -noout \
    | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary | openssl enc -base64
  ```

  Always pin a backup key (generated and stored offline) so a certificate rotation does not lock the fleet out.
- The S3 upload host is deliberately **not** pinned (pre-signed part URLs, background session).
- To verify on the first macOS build: that Xcode expands `$(DS_API_HOST)` used as a dictionary *key* under
  `NSPinnedDomains` in the processed Info.plist. If it does not, generate the `NSPinnedDomains` dictionary in a
  pre-build script (PlistBuddy) from the same build settings.

## Test target linking (compile-risk fix 1)

`DengueCaptureTests` depends on the host app and on the `DengueCaptureCore` package product with
`link: false`: the module is visible to `import DengueCaptureCore`, while the code is the single static copy
inside the host app (no duplicate class definitions). Tests use `@testable import DengueCapture`.
UI tests do not import the core package (expected strings are mirrored from `NurseCopy`).

## Sessions, consent and capture (C2, I1, I2)

- Sign-in: OIDC; core `SessionGate`/`SessionPolicy` decide the root screen: 10 min idle -> lock overlay with
  LAContext device-owner authentication; 12 h without server validation -> sign out and delete tokens. After a
  relaunch the stored tokens are trusted only after a successful refresh (otherwise sign in again).
- Consent: `ConsentService` (online lookup + consent status). Offline, the cached ward roster is used for at
  most 24 h. The roster file (participant codes + consent flags) is Class C and excluded from backup.
- Device enrolment (App Attest) runs after the first sign-in; the token is renewed from 4 h before expiry.
- Positioning: the face step shows a live preview with the oval and guidance; Start is enabled only after
  2 s of continuous "Ready". The camera then plans ISO from the converged auto exposure, locks and reads back
  every setting (`CameraConfigurator`), and records.
- Repeats: a server-requested repeat appears in Uploads (and as an in-app banner) for 2 h after capture;
  "Record again" records the listed steps and queues a recapture. After 2 h the session is closed as an
  acquisition failure.

## Open items before pilot (not built)

1. **`POST /v1/devices/events`**: backend endpoint for `device_event` audit (screen capture detected/ended,
   assent declined). The app records these locally only (`LocalDeviceEventSink`).
2. **App Attest server verifier**: the real verifier must check the attestation and assertions with
   nonce = SHA256(authData || SHA256(challenge)) (the API currently has the verifier interface only).
3. **Quality worker**: must write `scan_step_attempts.server_verdict` in {`PASS`, `FAIL`}, unwrap each
   artefact's data key through KMS (`backend/src/crypto/kms.ts`, `AwsKmsUnwrapper`, `RSAES_OAEP_SHA_256`)
   and decrypt with `openSealed` (`backend/src/crypto/sealedArtefact.ts`).
4. **KMS key provisioning and rotation**: create the asymmetric RSA_3072 (or 4096) KMS key
   (ENCRYPT_DECRYPT), distribute its public key and id through MDM (`kms_public_key_pem`, `kms_key_id`),
   restrict `kms:Decrypt` to the quality worker role, and define rotation (old key ids must stay decryptable
   for artefacts already uploaded).
5. Server close of repeat-window expiries: a repeat not offered after 2 h is closed on the phone only; the scan
   stays `quality_failed` on the server until a reviewer or the worker closes it.
