# Quill

Sign and install IPAs directly on the iPhone, with your own certificate or your Apple ID, no computer required. Requires **iOS 27**.

## Status

| Part | State |
| --- | --- |
| Rust core `QuillCore` | builds without warnings, 10 unit tests pass |
| App and widget | build in CI with Xcode 27, no warnings in project code |
| On-device behaviour | early testing; pairing, sign-in and installation are not yet verified end to end |

## Download

Every push to `main` builds an unsigned IPA and publishes it as the `latest` release:
**Releases → Latest build → Quill.ipa**. Sign it with your own account before installing.

## Build locally

Requirements: macOS with Xcode 27, Homebrew, Rust (rustup).

```sh
brew install xcodegen
./setup.sh            # fetches Zsign, builds the Rust core, generates the project
open Quill.xcodeproj
```

After changing the Rust core run `REBUILD_CORE=1 ./setup.sh`. In Xcode, pick your team under *Signing & Capabilities* and adjust the bundle ID (`com.example.quill`) and app group.

## Setup on the iPhone

1. Turn on **Developer Mode** (Settings → Privacy & Security).
2. Install **LocalDevVPN** from the App Store. Quill reaches the device services through it at `10.7.0.1:49152`.
3. In Quill choose **Koppeln ohne Computer**, then pick Quill in Settings → Privacy & Security → Developer Mode and enter the code Quill shows.
4. Connect LocalDevVPN. The status row shows the device as paired.
5. Sign in with your Apple ID, or import a `.p12` with a matching profile.

## Features

| Area | What it does |
| --- | --- |
| Sign & install | Pick an IPA or load one from a URL; signs and installs in one step with progress and log |
| Installed apps | Remaining days, refresh (keeps data), refresh all, remove, reminder one day before expiry |
| Apple account | Sign-in with 2FA, team selection, device registration, app IDs, automatic certificate and profiles |
| Pairing | On-device pairing (iOS 27), import of a remote pairing file, `quill://pairing?data=…` |
| UDID | Detected through pairing, a temporary Safari profile, or manual entry |
| Certificates | Import `.p12` / `.mobileprovision` / `.cer` / `.zip`, export `.p12` behind Face ID, CSR, revocation check |
| LiveContainer | Downloads the official release, signs it and exports the certificate for JIT-less mode |
| Automation | App Intents for Shortcuts: refresh apps, status, days until expiry |
| Widget | Home Screen, Lock Screen and a Control Center button |
| Other | File browser, app library, AltStore-format sources, Wi-Fi transfer, `itms-services` fallback |

## Automatic refresh

Create a personal automation in Shortcuts (daily, run immediately):

1. *Set VPN* → LocalDevVPN → Connect
2. *Wait* 3 seconds
3. *Apps erneuern* (Quill)
4. optionally *Set VPN* → Disconnect

The Apple ID password must be saved for refresh. If Apple asks for a verification code, the action stops with a message instead of hanging.

## Layout

```
QuillCore/        Rust core (static library), C header in include/
  src/pairing.rs  pairable host, pairing code, pairing file
  src/device.rs   remote pairing → TLS-PSK tunnel → RSD → lockdown, AFC, installation
  src/account.rs  Apple sign-in, 2FA, teams, app IDs, signing (isideload)
  src/crypto.rs   CSR and PKCS#12 helpers
Quill/            SwiftUI app (App, Services, Features, Intents, Shared)
QuillWidget/      widget and Control Center extension
scripts/          build-core.sh
```

## Privacy

Keys, the pairing file and credentials stay on the device (file protection, device-only keychain). During Apple sign-in Quill talks to Apple and to an **anisette server** (default `ani.iloader.app`, configurable in settings) that provides device identifiers an app cannot generate itself. That server sees the IP address, not the password.

## Known limits

- iOS 27 only.
- LocalDevVPN is required for direct installation.
- Free Apple IDs: 7 days validity, three active apps, a small weekly app ID quota.
- Background refresh by iOS is best effort; the Shortcuts automation is the reliable path.
- While pairing or detecting the UDID, Quill plays silent audio to stay alive in the background.
- The widget needs an app group; without it the app works and the widget shows a hint.
- The app UI is German only.

## Dependencies

- [idevice](https://github.com/jkcoxson/idevice) (MIT): pairing, tunnel, device services
- [isideload](https://github.com/nab138/isideload) (MIT): Apple account and developer services
- zsign (MIT) via `khcrysalis/Zsign-Package`, with OpenSSL (Apache 2.0)
- ZIPFoundation (MIT)
- Rust crates under MIT/Apache-2.0, see `QuillCore/Cargo.lock`
