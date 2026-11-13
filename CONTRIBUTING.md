# Contributing to Open Remote for LG TV

Thanks for helping! A few ground rules keep the app small, private and reliable.

## Principles

- **Privacy first.** No analytics, crash reporters, ads, accounts or network calls to anything
  except TVs on the local network. PRs that add any of these will not be merged.
- **Zero third-party dependencies.** Apple frameworks only.
- **Lightweight.** SF Symbols over image assets; no large resources.
- **Accessible.** Every control has an accessibility label, works with VoiceOver and Dynamic
  Type, and looks right in light/dark mode and on iPad.
- **Original.** Don't copy the look, assets or text of other remote apps, and don't use LG logos
  or trademarks beyond describing compatibility.

## Getting started

```sh
open OpenRemote.xcodeproj
cd Packages/LGKit && swift test
```

Simulator builds need no setup. For a physical device, put your own `DEVELOPMENT_TEAM` and
`BUNDLE_ID_PREFIX` in `Config/Signing.local.xcconfig` (ignored by git) rather than changing
signing in Xcode, so the project file stays out of your PR.

- TV logic lives in `Packages/LGKit` and must be testable on macOS (`swift test`). Add a test
  for protocol or parsing changes, and keep `MockTV` in sync with `TVControlling`.
- UI lives in `OpenRemote/`. Views read `TVSession` from the environment and talk to the TV
  only through `TVControlling`. Use the tokens in `Shared/Theme.swift` and `Haptics`.
- For UI work without a TV, use a **Debug simulator** build with `-demo`. This opt-in
  fixture supports screenshots and previews; it is unavailable on physical devices and in
  Release builds, and never restores on a normal launch. Test real-TV behaviour on a webOS
  TV and note the model and webOS version in your PR.
- If you use a new [required-reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
  (file timestamps, system boot time, disk space, user defaults, active keyboards), update
  `OpenRemote/Resources/PrivacyInfo.xcprivacy` in the same PR.

## Pull requests

- Keep PRs focused; describe what changed and how you tested it (simulator/device, TV model).
- Swift 5 language mode, Swift API Design Guidelines, no force-unwraps on external data,
  nothing blocking the main thread, no new warnings.
- Comment only where the intent isn't obvious.

## Reporting security issues

Please don't open a public issue for security problems. See [SECURITY.md](SECURITY.md).

## Reporting bugs

Open an issue with your TV model (Settings → General → About This TV), webOS version, iOS
version, iPhone/iPad model, and steps to reproduce.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
