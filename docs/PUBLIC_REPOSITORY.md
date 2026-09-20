# Public repository and local configuration

This repository contains a sanitized copy of the original commit history. Authors,
dates, commit order, and both development branches were retained. Commit hashes
changed because private deployment data was removed throughout the history.
The working changes present during migration were included in a separate commit.

Production IP addresses, domains, access credentials, and Firebase configuration
are not distributed here. Addresses under `netlumavpn.example` and `192.0.2.0/24`
are documentation placeholders. Historical deployment observations describe the
original private environment; they are not connection instructions for this copy.

Private server runbooks (`*_MVP_SERVER.md`, `docs/SSH_ACCESS.md`), generated PDF
reports/screenshots, local build caches, and the encrypted `design.pen` asset were
excluded from every commit. The original private checkout retains them. Application,
extension, widget, backend, infrastructure, tests, and vendored source code remain.

## Configure your own backend

1. Copy `Config/Backend.local.plist.example` to `NetlumaVPN/Backend.local.plist`.
2. Set `mobileAPIBaseURL` to your HTTPS backend and `mobileClientKey` to its
   least-privilege mobile key. Never put an administrative API key in the app.
3. Set `mobileTLSCertificateSHA256Base64` if certificate pinning is required.
4. Run `xcodegen generate` so the optional local resource is included in the app.

`Backend.local.plist` is ignored by Git. Missing or malformed configuration uses
an example endpoint and an empty key. Imported user profiles continue to work
independently of the managed-server catalog. Values bundled into an app can be
extracted from that app; the mobile key is not an administrative security boundary.

Firebase is optional. To enable it, add your own ignored
`NetlumaVPN/GoogleService-Info.plist`, then regenerate the project. Without this file,
initialization, telemetry, and Crashlytics symbol upload are skipped.

Use environment variables and `ops/quickvpn.env.example` for server deployment.
Supply your own host, SSH user, port, and key through the deployment script's
documented variables. Keep actual server credentials outside this repository.

## Validate before publishing

Run Gitleaks over all branches, not only the latest diff:

```sh
gitleaks git . --log-opts=--all --redact=100
```

Run the tests in [TESTING.md](TESTING.md). Do not merge the original unfiltered
history into this repository: it would restore removed data. Port future changes
as reviewed patches, using this sanitized history as the public baseline.

## Migration validation (2026-09-20)

- All 10 original commits retain their authors, dates, and parent relationships.
- Both branches and the requested uncommitted application/backend changes are included.
- Gitleaks with decoding enabled found no secrets in the sanitized history; a separate
  full Git-object scan confirmed removal of the inventoried private deployment values.
- All 16 backend tests and all 6 UI tests passed.
- The app built successfully on the iOS simulator. Of 119 unit tests, 118 passed,
  including the new local-configuration tests. The existing
  `shippingBundlesDeclareExportComplianceCodeBuildSetting` test still fails because
  the main app declares `ITSAppUsesNonExemptEncryption = false`; see known issue #15.
  The migration preserves that existing declaration and does not claim a fully green suite.
