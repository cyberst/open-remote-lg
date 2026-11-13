# Privacy Policy — Open Remote for LG TV

_Last updated: 11 November 2026_

Open Remote for LG TV ("Open Remote", "the app") is a free, open-source remote control for
LG webOS smart TVs, made by independent contributors. This policy explains what the app
does with information. The short version:

> **Open Remote collects no data.** There are no accounts, no analytics, no advertising,
> no tracking and no servers of ours. TV control and media streaming stay on your local network.
> Voice recognition uses Apple's speech service when on-device recognition is unavailable.

## What the app does not do

- It does not collect, store on our side, sell or share any personal information.
- It does not use analytics, crash-reporting, advertising or tracking services, and it
  contains no third-party code (SDKs) at all.
- It does not track you across apps or websites and does not use the advertising identifier.
- It does not require or offer an account or sign-in.

## Network connections

Open Remote connects directly to devices on your local network for TV features:

- **Finding TVs** — it sends discovery messages (SSDP and Bonjour) on your Wi‑Fi to find
  compatible TVs. iOS asks you for **Local Network** permission the first time.
- **Controlling your TV** — it opens a direct connection (WebSocket) from your iPhone or
  iPad to the TV to send commands such as key presses, volume, app launches and text.
- **Turning your TV on** — it can send a Wake-on-LAN packet on your local network.
- **Showing photos and videos** — when you choose media to show on the TV, the app serves
  that file from your device to the TV over your local network for as long as it plays.
  Nothing is uploaded to the internet.

The app does not contact any internet server operated by us. Apple's Speech framework may
connect to Apple's servers for voice recognition when on-device recognition is unavailable,
as described below.

## Information stored on your device

To work, the app keeps a small amount of information **only on your device**:

- the TVs you have connected to (name, model, IP address and network MAC address, used to
  reconnect and to switch the TV on);
- the pairing key your TV issues when you accept the connection (kept in the iOS Keychain);
- your settings (for example the preferred remote layout).

This information never leaves your device except as needed to talk to your own TV. You can
remove a TV in the app's TV list, which deletes its pairing key. Deleting the app removes
its saved TVs and settings. Your device's own encrypted backups may include this data, as
with any app.

## Permissions

The app only asks for a permission when you use the feature that needs it:

| Permission | Used for |
|---|---|
| Local Network | Finding and controlling TVs on your network |
| Microphone & Speech Recognition | Only while you give a voice command, to turn it into a TV action |
| Motion | Only in Air Mouse mode, to move the TV's pointer |
| Photos | Only to show photos or videos you choose on your TV |

**Voice commands** use Apple's Speech framework. When your device supports it, recognition
happens entirely on the device. On devices that don't, Apple may process the audio to
transcribe it, under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/). The
developers do not receive audio or transcripts. Apart from Apple's speech processing,
the app does not send them to other services; the resulting command goes to your TV.

Your TV itself is made by LG Electronics and has its own privacy settings and policies,
which this app does not control.

## Children

The app is suitable for all ages and collects no information from anyone, including children.

## Open source

The app's complete source code is public, so anyone can verify these statements:
<https://github.com/OWNER/open-remote-lg>.

## Changes

If this policy ever changes, the updated version will be published at this address with a
new "Last updated" date. Because the app collects nothing, we have no way to notify you
directly.

## Contact

Questions about privacy: open an issue at
<https://github.com/OWNER/open-remote-lg/issues>.

---

Open Remote is an independent, community-made app and is not affiliated with, endorsed by,
or sponsored by LG Electronics. LG and webOS are trademarks of their respective owners.
