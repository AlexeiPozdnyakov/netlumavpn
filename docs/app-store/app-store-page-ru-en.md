# NetlumaVPN App Store Page

Prepared: 2026-06-24

This file contains ready-to-copy App Store Connect metadata for English and Russian localizations, plus the review, privacy, and submission notes that matter for the current build.

## Current Project Facts

- App: NetlumaVPN
- Version/build in project: 1.0 / 1
- Bundle ID: `com.alekseipozdiakov.NetlumaVPN`
- Platforms: iPhone and iPad, iOS 17+
- Primary app type: VPN/proxy client using Network Extension packet tunnel
- Supported profile imports: VLESS, VMess, Trojan, WireGuard, sing-box JSON for supported outbound types, config URL import, QR import, manual profile editor
- User-facing controls: one-tap connect/disconnect, local profiles, global servers, DNS resolver selection, IPv4/IPv6 mode, On Demand, Persist Tunnel, Include All Networks, session details, widget
- Privacy posture in code: sensitive profile secrets are stored in Keychain; profile metadata and selected profile state are stored locally through App Group storage; diagnostics are sanitized

## Submission Blockers Before Review

Fix these before sending the build to App Review:

1. StoreKit is not wired, but onboarding and settings currently show Premium plans, trial wording, and prices. Either remove/disable those screens for the App Store build or implement real App Store subscriptions and submit matching IAP products.
2. Current onboarding copy includes absolute claims such as "Stay anonymous on any network", "fully protected", and "Military-grade encryption". Replace with softer, accurate language before review.
3. The app must show a clear data-use/privacy declaration before the user purchases or uses the VPN service. Terms and Privacy links exist, but make sure the first-run flow satisfies Apple's VPN guideline.
4. Publish real support, privacy, and terms URLs before submission. App Store Connect requires a privacy policy URL and a support URL with actual contact information.
5. Confirm the backend hostname and global server provisioning are production-ready. The code currently points to `https://vpn.netlumavpn.example`, while docs mention `api.netlumavpn.example`.
6. Export compliance is required because `ITSAppUsesNonExemptEncryption` is true.
   After App Store Connect accepts the encryption documentation, pass
   `APP_STORE_EXPORT_COMPLIANCE_CODE=<code from App Store Connect>` as an `xcodebuild`
   archive build setting, or for Xcode's Product → Archive flow copy
   `Config/AppStoreExportCompliance.local.xcconfig.example` to
   `Config/AppStoreExportCompliance.local.xcconfig` and put the code there. The helper
   `ops/set-app-store-export-compliance-code.sh <code from App Store Connect>` writes
   that gitignored file. This populates `ITSEncryptionExportComplianceCode` in the app
   and extension plists. The archive build fails locally if this value is missing.
7. Before upload, confirm the `.xcarchive/dSYMs` directory contains dSYMs for embedded
   vendor frameworks including `FirebaseAnalytics.framework`,
   `GoogleAdsOnDeviceConversion.framework`, `GoogleAppMeasurement.framework`,
   `GoogleAppMeasurementIdentitySupport.framework`, and `SwiftyXrayCore.framework`.
   The app target now generates these from the embedded framework binaries during archive.

## App Information

Recommended App Store category:

- Primary Category: Utilities
- Secondary Category: Productivity, optional
- Made for Kids: No
- Content Rights: Does not contain or provide third-party media content. Users are responsible for imported VPN profiles and server access.

URLs to publish before submission:

- Support URL: `https://netlumavpn.example/support`
- Marketing URL: `https://netlumavpn.example`
- Privacy Policy URL: `https://netlumavpn.example/privacy`
- Terms URL: `https://netlumavpn.example/terms`

## English Metadata

Locale: `en-US`

App Name, 30 characters max:

```text
NetlumaVPN: VPN Proxy
```

Subtitle, 30 characters max:

```text
Private VPN Client & Servers
```

Promotional Text, 170 characters max:

```text
Import trusted VPN profiles, connect in one tap, tune DNS, and check your session details in a clean iOS app.
```

Keywords, 100 bytes max:

```text
secure,tunnel,privacy,wifi,qr,import,vmess,trojan,xray,reality,ip,network,firewall,private
```

Description, 4000 characters max:

```text
NetlumaVPN is a clean iOS VPN client for people who use trusted VPN and proxy profiles and want direct control over how their tunnel behaves.

Import a configuration link, scan a QR code, or add a profile manually. NetlumaVPN supports VLESS, VMess, Trojan, and WireGuard profiles, including modern transport options such as TLS, Reality, WebSocket, gRPC, and HTTP Upgrade where supported by your configuration.

Connect in one tap
Choose a local profile or an available Netluma global server, then start or stop the VPN from the main screen. The app shows connection state, selected location, and session duration without clutter.

Tune the tunnel
Control IPv4/IPv6 mode, persistent tunnel behavior, Connect On Demand, and Include All Networks. DNS settings include standard DNS, DNS over HTTPS, and DNS over TLS resolver options.

See what the network sees
Session details show the public IP, ASN, organization, region, and city visible from the current connection, so you can confirm where traffic appears to exit.

Built for privacy-aware use
Sensitive profile values such as user IDs, passwords, and private keys are stored in Keychain. Non-sensitive profile metadata and settings stay in app group storage for the app, tunnel extension, and widget. Diagnostic logs are sanitized and avoid secrets.

NetlumaVPN is designed for lawful connections to servers you own or are authorized to use. VPN availability, speed, privacy, and website access depend on your selected server, DNS resolver, network, device, and local laws. A VPN improves privacy on some networks, but it does not make you anonymous or protected from every risk.
```

What's New:

```text
Initial App Store release of NetlumaVPN with one-tap VPN connection, profile import, QR scanning, DNS and tunnel controls, session details, widget support, and English/Russian localization.
```

Note: App Store Connect does not show "What's New" for the first version. Keep this text for the first update or TestFlight notes.

## Russian Metadata

Locale: `ru-RU`

App Name, 30 characters max:

```text
NetlumaVPN: VPN и прокси
```

Subtitle, 30 characters max:

```text
Приватный VPN и серверы
```

Promotional Text, 170 characters max:

```text
Импортируйте доверенные VPN-профили, подключайтесь в один клик, настраивайте DNS и смотрите детали сессии.
```

Keywords, 100 bytes max:

```text
приватность,туннель,wifi,qr,импорт,vmess,trojan,xray,reality,ip,сеть
```

Description, 4000 characters max:

```text
NetlumaVPN - аккуратный VPN-клиент для iPhone и iPad, который помогает подключаться через доверенные VPN и proxy-профили и управлять параметрами туннеля без лишнего шума.

Импортируйте ссылку конфигурации, сканируйте QR-код или добавляйте профиль вручную. NetlumaVPN поддерживает VLESS, VMess, Trojan и WireGuard, а также современные параметры транспорта, включая TLS, Reality, WebSocket, gRPC и HTTP Upgrade, если они есть в вашей конфигурации.

Подключение в один клик
Выберите локальный профиль или доступный глобальный сервер Netluma, затем включайте и отключайте VPN с главного экрана. Приложение показывает состояние соединения, выбранную локацию и длительность сессии.

Настройка туннеля
Управляйте режимом IPv4/IPv6, постоянным туннелем, подключением по требованию и Include All Networks. В настройках DNS доступны обычный DNS, DNS over HTTPS и DNS over TLS.

Проверка текущей сети
Экран сессии показывает публичный IP, ASN, организацию, регион и город, которые видны из текущего подключения. Это помогает быстро проверить, откуда выходит трафик.

С учетом приватности
Чувствительные данные профилей, включая user ID, пароли и приватные ключи, хранятся в Keychain. Метаданные профилей и настройки остаются локально в App Group storage для приложения, туннельного расширения и виджета. Диагностические журналы очищены от секретов.

NetlumaVPN предназначен для законных подключений к серверам, которыми вы владеете или которыми вам разрешено пользоваться. Доступность VPN, скорость, приватность и доступ к сайтам зависят от выбранного сервера, DNS-резолвера, сети, устройства и местных законов. VPN может повысить приватность в некоторых сетях, но не делает вас полностью анонимными и не защищает от всех рисков.
```

What's New:

```text
Первый релиз NetlumaVPN в App Store: подключение VPN в один клик, импорт профилей, сканирование QR-кодов, настройки DNS и туннеля, детали сессии, виджет и локализация на русском и английском.
```

Note: App Store Connect does not show "What's New" for the first version. Keep this text for the first update or TestFlight notes.

## Screenshot Copy

Existing App Store screenshot frames in `design.pen`:

English:

1. Connect in one tap - Fast, private and reliable VPN - built around your profile.
2. Everything in one place - Manage your plan, billing and all your settings.
3. Tune every connection. - Persistent tunnel, On-Demand and IPv6 - exactly your way.
4. Your DNS, your rules. - DoH, DoT, DoQ - Cloudflare, Google and your own resolver.
5. See what the network sees. - Live IP, ASN and location - no guesswork.

Russian:

1. Подключение в один клик - Быстрый и приватный VPN - под твой профиль.
2. Все в одном месте - Подписка, оплата и все настройки.
3. Контроль над соединением - Постоянный туннель, On-Demand и IPv6 - как тебе удобно.
4. Свой DNS, свои правила - DoH, DoT, DoQ - Cloudflare, Google и собственный резолвер.
5. Что видит сеть - Реальный IP, ASN и локация - все на виду.

Screenshot safety notes:

- Do not upload screenshot 2 until subscriptions and billing are actually implemented.
- Change "DoQ" in screenshot 4 unless DNS over QUIC is implemented; the current code includes DoH, DoT, and standard DNS.
- Prefer avoiding "private" as an absolute promise. A safer first screenshot subtitle is "Fast VPN control - built around your profile."

## App Review Notes

Copy this into App Review notes after filling the placeholders:

```text
NetlumaVPN is an iOS VPN client that uses Apple's Network Extension packet-tunnel-provider capability. The app supports user-provided VLESS, VMess, Trojan, and WireGuard profiles, plus optional Netluma-managed global server provisioning when servers are available.

No account is required for the current app flow. Users can import a profile by URL, scan a QR code, add a profile manually, select DNS/tunnel preferences, and connect/disconnect from the main screen. Sensitive profile secrets are stored locally in Keychain. Profile metadata and selected settings are stored locally using App Group storage so the app, packet tunnel extension, and widget can access the selected connection state.

The app does not include advertising SDKs and does not track users across apps or websites. Global server provisioning sends a random device ID stored in Keychain and the device model to the Netluma server so a temporary profile can be issued. Session details may request public IP and coarse network information from ipapi.co when the user opens the Session screen.

Testing:
1. Launch the app and complete onboarding.
2. To test a user-provided profile, import the demo configuration below or scan its QR equivalent.
3. Tap Connect and approve the iOS VPN permission prompt.
4. Open Settings to review Tunnel, DNS, Terms of Use, and Privacy Policy.
5. Open Session details to verify public IP and network information.

Demo VPN profile for review:
[PASTE A LEGAL, TEMPORARY, NON-PRODUCTION TEST PROFILE HERE]

Support contact:
[PASTE SUPPORT EMAIL/PHONE/URL HERE]
```

If subscriptions are implemented later, add the subscription products to the notes and include sandbox test guidance. If subscriptions are not implemented, do not submit any IAP products and remove paywall pricing from the build.

## Privacy Nutrition Label Draft

Verify with the final backend logging policy before submission. Suggested conservative answers based on the current code:

- Tracking: No
- Third-party advertising: No
- Data linked to the user: none intentionally for imported local profiles
- Data not linked to the user, used for App Functionality:
  - Identifiers: random device ID for Netluma global server provisioning
  - Device information: device model sent while issuing a Netluma-managed profile
  - Location/coarse network data: public IP-derived country, region, city, ASN, and organization shown in Session details
  - Diagnostics: sanitized local connection logs, if considered collected only when shared through support
- Local-only data:
  - Imported VPN profile metadata
  - VPN credentials, passwords, user IDs, and private keys stored in Keychain
  - DNS and tunnel preferences

Privacy policy must clearly state:

- NetlumaVPN does not sell user data.
- NetlumaVPN does not use VPN data for advertising or tracking.
- Imported third-party VPN providers and selected DNS resolvers may process traffic or DNS data under their own policies.
- If Netluma-operated servers are offered, state exactly what server-side logs are kept, for how long, and for what purpose.

## Future In-App Purchase Copy

Use only after StoreKit and App Store subscriptions are implemented.

Subscription group:

| Locale | Display Name |
|---|---|
| `en-US` | NetlumaVPN Premium |
| `ru-RU` | NetlumaVPN Premium |

Products:

| Product | Product ID | Type |
|---|---|---|
| Weekly Premium | `com.alekseipozdiakov.NetlumaVPN.premium.weekly` | Auto-renewable subscription |
| Monthly Premium | `com.alekseipozdiakov.NetlumaVPN.premium.monthly` | Auto-renewable subscription |
| Annual Premium | `com.alekseipozdiakov.NetlumaVPN.premium.annual` | Auto-renewable subscription |

Use the same product IDs in App Store Connect, StoreKit configuration files, server-side receipt validation, and app code. Product IDs are case-sensitive; do not rename them after release unless you intentionally migrate users to new products.

Product localizations:

| Product ID | Locale | Display Name | Description |
|---|---|---|---|
| `com.alekseipozdiakov.NetlumaVPN.premium.weekly` | `en-US` | Weekly Premium | Global servers and premium tools |
| `com.alekseipozdiakov.NetlumaVPN.premium.weekly` | `ru-RU` | Недельная подписка | Глобальные серверы и Premium-инструменты |
| `com.alekseipozdiakov.NetlumaVPN.premium.monthly` | `en-US` | Monthly Premium | Flexible access to global VPN tools |
| `com.alekseipozdiakov.NetlumaVPN.premium.monthly` | `ru-RU` | Месячная подписка | Гибкий доступ к глобальным VPN-инструментам |
| `com.alekseipozdiakov.NetlumaVPN.premium.annual` | `en-US` | Annual Premium | Best value for global VPN access |
| `com.alekseipozdiakov.NetlumaVPN.premium.annual` | `ru-RU` | Годовая подписка | Лучшая цена для глобального VPN-доступа |

Subscription price text should come from StoreKit localized pricing, not from hardcoded App Store descriptions.

## Official Apple References

- App information limits: https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/
- Version metadata limits: https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/
- Product page guidance: https://developer.apple.com/app-store/product-page/
- App privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Manage app privacy: https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/
- VPN App Review guideline: https://developer.apple.com/app-store/review/guidelines/
