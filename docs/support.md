# Support — Open Remote for LG TV

Open Remote is a free, open-source remote for LG webOS smart TVs (2014 and newer).
Need help, found a bug, or have an idea? Open an issue:
**<https://github.com/cyberst/open-remote-lg/issues>** — please include your TV model
(Settings → General → About This TV), the webOS version, and your iOS version.

## Getting connected

1. Make sure your iPhone/iPad and the TV are on the **same Wi‑Fi network** (guest networks
   and "AP/client isolation" block devices from seeing each other).
2. Switch the TV on. Open Open Remote and pick your TV from the list.
3. The first time, the TV asks you to **allow** the connection — press OK with the TV's own
   remote — or shows a **PIN** to type into the app. The TV's message may not name the app
   ("… is trying to connect"): LG shows names only for apps it has signed. That's expected.

## Troubleshooting

**My TV doesn't appear in the list.**
- Allow **Local Network** access: iOS Settings → Privacy & Security → Local Network →
  Open Remote.
- Check both devices are on the same network, then pull to refresh the list.
- Add the TV manually by its IP address (TV: Settings → Network → Wi‑Fi/Wired connection →
  Advanced settings).
- Restart the TV (unplug it for 30 seconds) and your router if discovery still fails.

**It connects, then asks to pair again.**
Your TV may have been reset or its list of connected devices cleared. Accept the prompt
again; the app stores the new key.

**I can't turn the TV on from the app.**
Turning on over the network needs the TV option **"Turn on via Wi‑Fi"** / **"Mobile TV On"**
(Settings → General → Devices → TV Management or External Devices, depending on model).
Some TVs only support this over a wired connection or for a few minutes after switching off.
Version 1.0 sends wake packets directly to the saved TV address; broadcast waking is not
available. If your router no longer knows how to reach the sleeping TV, use the TV's own
remote to switch it on. Other remote controls work once the TV is on.

**The pointer (touchpad / air mouse) doesn't move.**
The pointer appears on screens that support it. Press a d-pad key on the TV remote once, or
open the home screen, then try again.

**Voice commands don't work.**
Allow Microphone and Speech Recognition for Open Remote in iOS Settings, then start a
voice command and speak.

**The sleep timer didn't turn the TV off.**
The sleep timer runs in the app: keep Open Remote open and on screen until it ends. If the
app is closed or in the background, the TV stays on. (The TV's own sleep timer can't be set
from a phone.)

**Photos or videos won't play on the TV.**
The TV fetches media directly from your iPhone/iPad, so keep the app open while it plays.
Very large or unusual video formats may not be supported by your TV.

## Privacy
Open Remote collects no data. Read the [privacy policy](privacy-policy.md).

---
Open Remote is not affiliated with, endorsed by, or sponsored by LG Electronics.
