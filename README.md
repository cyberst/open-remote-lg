# Open Remote for LG TV

A free, private, open-source iPhone and iPad remote for LG webOS smart TVs (2014 and newer).
No ads. No accounts. No analytics. No tracking. TV control stays on your home network.

## Features

- **Your remote** — pick the LG remote that looks like yours from 14 illustrated layouts and
  press its keys on screen
- **Touchpad** — move the TV pointer, tap to click, two-finger scroll
- **Phone pointing** — point and move your phone to steer the cursor
- **Keyboard** — type into the TV with your iPhone/iPad keyboard
- **Voice commands** — speak a command; on-device recognition where supported
- **Inputs & apps** — switch HDMI/antenna inputs; launch and arrange installed apps
- **Cast** — show photos and videos from your library on the TV
- **Sleep timer** (runs in the app: the TV is switched off only if the app is still open in the
  foreground; the TV's own timer can't be set remotely)
- **Multiple TVs**, **Wake-on-LAN**, automatic discovery
- Haptics, VoiceOver, Dynamic Type, light/dark mode, iPhone and iPad layouts

## Privacy promise

Open Remote collects nothing: no analytics, crash reporting, ads, accounts or servers, and
zero third-party dependencies. TV traffic stays on your local network (discovery, control,
Wake-on-LAN, and a local stream when you show media). The one exception is voice commands:
when your device can't recognise speech on-device, iOS sends the audio to Apple's speech
service. Saved TVs and settings stay on your device; TV pairing keys are kept in the Keychain. See the
[privacy policy](docs/privacy-policy.md) and the app's
[privacy manifest](OpenRemote/Resources/PrivacyInfo.xcprivacy).

## Supported TVs

LG smart TVs running **webOS 1.0 or later (2014 models onwards)** on the same network as the
iPhone/iPad. Older NetCast models (2013 and earlier) are not supported. Some features depend
on the TV's model and webOS version (e.g. the pointer is only shown on screens that support it).

## Building

Requirements: Xcode 26 or later (developed with Xcode 27), iOS 17+ deployment target.

```sh
open OpenRemote.xcodeproj           # scheme "OpenRemote", run on a simulator or device

# Core library + tests (macOS, no simulator needed)
cd Packages/LGKit && swift build && swift test

# App tests on a simulator (no signing needed)
xcodebuild test -project OpenRemote.xcodeproj -scheme OpenRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

Simulator builds work out of the box. To run on your own iPhone or iPad, create
`Config/Signing.local.xcconfig` (git ignores it) with your team and a bundle ID prefix:

```
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_PREFIX = com.yourname
```

There's no need to edit the Xcode project; see `Config/Signing.xcconfig`. The app target uses a file-system–synchronized folder: any file added under `OpenRemote/` is
compiled automatically.

| Tool | What it does |
|---|---|
| `python3 -I tools/tv.py <ssap-uri> [json]` | Sends one SSAP request to a test TV from the shell |
| [`tools/remotes/`](tools/remotes/README.md) | Prepares remote artwork and maps its keys |

## Architecture

```
OpenRemote/            SwiftUI app (iOS 17+, iPhone + iPad)
  App/                 OpenRemoteApp, RootView, TVSession (@Observable app state)
  Shared/              Theme (design tokens), Haptics
  Remote/ RemoteArt/ Touchpad/ Keyboard/ Voice/ Media/ …   one folder per feature
  Resources/           Asset catalog, remote artwork, PrivacyInfo.xcprivacy
Packages/LGKit/        Swift package — everything that talks to a TV, testable on macOS
  Core/                Contracts (TVControlling, DeviceStoring, …), models, MockTV (simulator/test fixture)
  WebOS/               LGTVClient: the webOS second-screen (SSAP) protocol over WebSocket
  Discovery/           SSDP + Bonjour discovery
  Wake/                Wake-on-LAN
  Storage/             Saved TVs (Application Support) and pairing keys (Keychain)
  MediaServer/         Local HTTP server that streams chosen photos/videos to the TV
  Voice/               Spoken phrase → TV command
  lgctl                Command-line tool for exercising a real TV
```

- Views never talk to the network directly. They read `TVSession` from the environment and
  call the `TVControlling` protocol: `session.send { try await $0.press(.home) }`.
- `TVControlling` has two implementations: `LGTVClient` (real TVs) and `MockTV` (Debug
  simulator screenshots/previews and macOS tests). The app has no user-facing demo mode.
- No third-party packages; only Apple frameworks (SwiftUI, Network, Speech, CoreMotion,
  PhotosUI, Security).

### How pairing works

1. **Discovery** — the app sends an SSDP `M-SEARCH` for
   `urn:lge-com:service:webos-second-screen:1` on the local network (plus Bonjour), and
   reads each TV's name, model and MAC address. You can also add a TV by IP address.
2. **Connect** — it opens a WebSocket to the TV (`wss://<tv>:3001`, falling back to
   `ws://<tv>:3000` on older models) and sends a `register` request with a permission
   manifest.
3. **Accept** — the first time, the TV shows an *Allow* prompt (or a PIN on some models).
   Once accepted, the TV returns a **client key**, which the app stores in the Keychain.
4. **Reconnect** — later connections send the stored client key, so no prompt appears.
   Commands are SSAP requests (`ssap://audio/volumeUp`, `ssap://system.launcher/launch`, …);
   remote buttons and the pointer go over the TV's separate pointer-input socket.
5. **Wake** — to switch a TV on, the app sends a Wake-on-LAN magic packet to the saved MAC
   address (the TV setting "Turn on via Wi‑Fi" must be enabled).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and feature
ideas: GitHub Issues. Please include your TV model and webOS version.

## License

[MIT](LICENSE) © 2026 Open Remote for LG TV contributors.

---

Open Remote is an independent, community-made app. It is not affiliated with, endorsed by, or
sponsored by LG Electronics. LG and webOS are trademarks of their respective owners.
