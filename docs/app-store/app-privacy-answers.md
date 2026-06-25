# NetlumaVPN App Privacy Answers

Prepared: June 25, 2026

Use this checklist in App Store Connect -> App Privacy. Apple requires an Account Holder or Admin to complete this section before the app can be submitted for review.

## Short Answer For The Current Blocker

The blocker in App Store Connect means the App Privacy section is empty. Fix it here:

1. Open App Store Connect.
2. Go to My Apps -> NetlumaVPN -> App Privacy.
3. Click Get Started or Edit.
4. Enter the Privacy Policy URL.
5. Answer the data collection questionnaire using the tables below.
6. Publish/save the privacy answers.
7. Return to the app version page and try Add for Review again.

Only an Account Holder or Admin can do this. If the current user is App Manager or Developer, ask the Apple Developer account Admin to fill it in.

## Recommended Top-Level Answers

| Question | Answer |
|---|---|
| Does this app collect data from this app? | Yes |
| Is data used to track users across apps and websites owned by other companies? | No |
| Does the app use third-party advertising? | No |

Do not answer "No data collected" for the current build. The app uses StoreKit, Firebase Analytics/Crashlytics, global server provisioning, and public IP/session lookup.

## Data Types To Select

Select the following data types.

### Location

| Apple Data Type | Select? | Purpose | Linked To User? | Tracking? | Notes |
|---|---:|---|---:|---:|---|
| Coarse Location | Yes | App Functionality | No | No | Session details and widget may request public IP-derived city/region/country from ipapi.co. |
| Precise Location | No | - | - | - | The app does not request GPS/Core Location. |

### Purchases

| Apple Data Type | Select? | Purpose | Linked To User? | Tracking? | Notes |
|---|---:|---|---:|---:|---|
| Purchase History | Yes | App Functionality, Analytics | Yes | No | StoreKit subscription state unlocks premium features. Firebase logs premium purchase events and transactions. |

### Identifiers

| Apple Data Type | Select? | Purpose | Linked To User? | Tracking? | Notes |
|---|---:|---|---:|---:|---|
| Device ID | Yes | App Functionality, Analytics | Yes | No | Netluma global server provisioning sends a random device ID stored in Keychain. Firebase may use an app instance identifier for analytics/crash reporting. |
| User ID | No | - | - | - | The current app flow does not require a Netluma account or user login. Imported VPN user IDs stay local in Keychain unless used in the selected VPN profile. |

### Usage Data

| Apple Data Type | Select? | Purpose | Linked To User? | Tracking? | Notes |
|---|---:|---|---:|---:|---|
| Product Interaction | Yes | Analytics | Yes | No | Firebase Analytics logs premium purchase flow events and may collect standard app interaction/session analytics. |
| Advertising Data | No | - | - | - | No advertising SDK or ad measurement flow is present. |
| Other Usage Data | No | - | - | - | Do not select unless more custom telemetry is added. |

### Diagnostics

| Apple Data Type | Select? | Purpose | Linked To User? | Tracking? | Notes |
|---|---:|---|---:|---:|---|
| Crash Data | Yes | Analytics, App Functionality | Yes | No | Firebase Crashlytics collects crash reports. |
| Performance Data | No | - | - | - | Firebase Performance is not present in the current code. |
| Other Diagnostic Data | Yes | Analytics, App Functionality | Yes | No | Network failure reports include sanitized method, host, path, status code, attempt count, and URL error code. |

## Data Types Not To Select

Do not select these for the current build unless the implementation changes:

- Contact Info
- Health and Fitness
- Financial Info
- Sensitive Info
- Contacts
- User Content
- Browsing History
- Search History
- Precise Location
- Advertising Data

Important VPN note: NetlumaVPN routes network traffic through the selected VPN/proxy server, but the app does not present that traffic as app content and does not intentionally collect browsing history in the app telemetry. VPN servers, imported third-party providers, DNS resolvers, and IP lookup services may process data under their own policies.

## Privacy Policy URL

Use the final public URL when available:

```text
https://netlumavpn.example/privacy
```

Do not submit with a placeholder URL. The page must be reachable without login and must describe:

- Local profile storage and Keychain storage.
- Netluma global server provisioning device ID and device model.
- StoreKit subscription status.
- Firebase Analytics and Crashlytics.
- Public IP/session lookup via ipapi.co.
- DNS resolver choices.
- Third-party VPN/profile providers.
- No sale of user data.
- No cross-app tracking and no third-party advertising.

## If Firebase Is Removed Before Submission

If Firebase Analytics and Crashlytics are removed from the release build, update the answers:

- Product Interaction: No, unless another analytics system remains.
- Crash Data: No, unless crashes are uploaded elsewhere.
- Other Diagnostic Data: No, unless network errors are uploaded elsewhere.
- Device ID may still be Yes for global server provisioning.
- Purchase History may still be Yes if StoreKit subscriptions remain.

## Source Of Truth In Code

Current privacy-impacting code paths:

- `NetlumaVPN/Services/FirebaseTelemetryReporter.swift`
- `NetlumaVPN/Services/PremiumSubscriptionService.swift`
- `NetlumaVPN/Services/GlobalServerAPIClient.swift`
- `NetlumaVPN/Services/GlobalServerDeviceIdentityStore.swift`
- `NetlumaVPN/Features/Settings/SessionInfoService.swift`
- `NetlumaVPNWidget/NetlumaVPNWidget.swift`
- `NetlumaVPN/Services/RemoteConfigDownloader.swift`
