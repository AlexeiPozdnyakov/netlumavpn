# NetlumaVPN App Encryption Documentation

Date: June 24, 2026

Prepared for: Apple App Store Connect - App Encryption Documentation

Developer / Publisher: Aleksei Pozdniakov

App name: NetlumaVPN

Bundle identifier: `com.alekseipozdiakov.NetlumaVPN`

Version / build: 1.0 / 1

Platform: iOS / iPadOS

## Purpose Of This Document

This document describes the encryption functionality used by NetlumaVPN for App Store Connect export-compliance review.

NetlumaVPN is a VPN/proxy client. It uses encryption to establish user-authorized VPN/proxy tunnels, protect transport sessions, store sensitive local profile data, and verify backend TLS identity. It does not expose a general-purpose cryptographic toolkit to end users.

If NetlumaVPN is distributed in France and App Store Connect requests a French encryption declaration, this technical document should be treated as supporting documentation. Apple and ANSSI may still require the official ANSSI declaration form or ANSSI attestation.

## App Summary

NetlumaVPN allows a user to import, create, store, select, and connect VPN/proxy profiles. The app supports profiles for VLESS, VMess, Trojan, and WireGuard, including TLS/Reality transport metadata where supported by the user's configuration. It uses Apple's Network Extension packet-tunnel-provider capability to start and stop the VPN tunnel.

The app includes:

- Main iOS app for profile import, profile selection, connection control, DNS settings, tunnel settings, and session details.
- Packet Tunnel Extension for VPN tunnel lifecycle and packet routing.
- Widget extension for connection state and quick actions.
- Local profile storage using App Group storage and Keychain-backed storage for sensitive secrets.

## Encryption Classification Statement

NetlumaVPN uses standard, publicly documented cryptographic algorithms and protocols through Apple system APIs and third-party VPN/proxy libraries. The developer of NetlumaVPN does not design or implement proprietary or unpublished cryptographic algorithms.

The app uses encryption in addition to encryption provided by Apple's operating system because VPN/proxy profiles may use WireGuard, Xray-compatible transports, TLS/Reality, and related tunnel encryption handled by linked VPN/proxy components.

Recommended App Store Connect answers, based on the current implementation:

- Does the app use encryption? Yes.
- Is encryption limited to that within Apple's operating system? No.
- Does the app use proprietary or non-standard encryption algorithms designed by the app developer? No.
- Does the app use standard encryption algorithms instead of, or in addition to, Apple's operating-system encryption? Yes.
- Is `ITSAppUsesNonExemptEncryption` set to true? Yes.

## Cryptographic Functionality

### VPN And Proxy Tunnels

Purpose: protect traffic routed through the selected VPN/proxy tunnel.

Related app features:

- User-provided VLESS profiles.
- User-provided VMess profiles.
- User-provided Trojan profiles.
- User-provided WireGuard profiles.
- Netluma-managed server profiles, when global servers are available.

Protocols and components:

- Apple's Network Extension framework is used for iOS tunnel lifecycle and packet flow.
- SwiftyXrayKit / Xray-compatible tunnel integration is used for Xray-style proxy transports when linked.
- WireGuard profile support is used for WireGuard configurations imported by the user.

Underlying cryptographic primitives may include standard algorithms used by those protocols and libraries, such as TLS 1.2/1.3 cipher suites, AEAD encryption, Curve25519/X25519-style key agreement, ChaCha20-Poly1305, AES-GCM, SHA-256-family hashing, and other standard primitives required by the selected protocol and server configuration.

The user or Netluma-managed backend provides the server configuration. NetlumaVPN does not allow users to create new cryptographic algorithms.

### HTTPS And Backend Communication

Purpose: fetch global server metadata, issue managed profiles, and download managed server configuration.

Implementation:

- HTTPS requests use Apple's URLSession and TLS stack.
- Optional TLS certificate pinning uses SHA-256 certificate digest comparison.
- CryptoKit SHA-256 is used only to compute a certificate digest for pin comparison.

Backend requests include app-level client headers and a random device identifier stored in Keychain for managed global-server provisioning. No VPN private keys, user passwords, or full generated tunnel configs are intentionally logged.

### Local Secure Storage

Purpose: store sensitive local profile values.

Implementation:

- User IDs, passwords, WireGuard private keys, and preshared keys are stored using iOS Keychain APIs.
- Non-sensitive profile metadata and preferences are stored in App Group storage.
- Keychain protection relies on Apple's operating-system security mechanisms.

### Session Diagnostics

Purpose: show current public IP and network information to the user.

Implementation:

- Session detail requests use HTTPS via Apple URLSession.
- The app may call an external IP information service to display public IP, ASN, organization, region, and city visible from the current connection.

## No Proprietary Cryptographic Algorithm Claim

NetlumaVPN does not contain a cryptographic algorithm created by Aleksei Pozdniakov or created specifically for this app.

The app does not modify standard cryptographic algorithms, does not provide cryptographic primitives as a developer API, and does not provide key-management services for third parties. Its cryptographic use is limited to operating VPN/proxy connections, securing transport to backend services, and storing local secrets.

## User Control And Access

Users can:

- Import or delete VPN/proxy profiles.
- Select which profile or global server to use.
- Start and stop the VPN tunnel.
- Choose DNS and tunnel preferences.
- Remove VPN permissions through iOS Settings.
- Delete the app to remove app data subject to normal iOS and Keychain behavior.

## Export Compliance Notes

Apple states that apps using encryption limited to Apple's operating system do not require App Store Connect documentation, while apps using industry-standard algorithms not provided within Apple's operating system may need to upload a French encryption declaration when distributed in France.

Because NetlumaVPN is a VPN/proxy app and can use third-party tunnel encryption outside Apple's operating-system encryption, it is appropriate to keep `ITSAppUsesNonExemptEncryption` set to true and provide encryption documentation when requested by App Store Connect.

For France, ANSSI describes a process for cryptology declarations and indicates that filings may include a completed/signed form, an electronic copy of the completed form, and required documentation in PDF/DOC/XLS format. This document can be used as the technical description portion of that package, but it is not itself an official ANSSI attestation.

## References

- Apple - Determine and upload app encryption documentation: https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/
- Apple - Export compliance documentation for encryption: https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/
- ANSSI - Contrôle réglementaire sur la cryptographie: les formulaires: https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-reglementaire-cryptographie-formulaires/
- ANSSI - Contrôle relatif à un moyen de cryptologie: https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/

## Declaration

To the best of the developer's knowledge, the information above describes the encryption functionality included in NetlumaVPN version 1.0 build 1.

Developer / Publisher:

Aleksei Pozdniakov

Signature:

________________________________________

Date:

June 24, 2026
