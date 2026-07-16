# Privacy Policy — Pocket Mac

**Last updated: 16 July 2026**

Pocket Mac lets you see and control your own Mac from your iPhone or a browser. It is free and
open source: every claim below can be verified in the source at
<https://github.com/agbanzy/pocket-mac>.

## The short version

**Pocket Mac collects nothing.** There is no account, no sign-up, no analytics, no advertising, no
tracking, and no third-party SDKs. We operate no database and have no server that can read your
data. Nothing you do in Pocket Mac is sent to us, because there is no "us" to send it to.

## What stays on your devices

- **Your encryption keys.** Your iPhone generates a private key that never leaves the device (it is
  held in the iOS keychain). The browser client stores its key in that browser's local storage.
- **Your pairing.** Which Mac you have paired, and its public key, are stored only on your device.
- **Your settings.** Action-deck tiles, layout, and preferences stay on your device.
- **Your screen, keystrokes, and clicks.** These travel only between your own devices.

Uninstalling the app deletes all of it. There is no cloud copy.

## What the relay can and cannot see

When your phone and Mac are not on the same network, traffic is routed through a relay server so the
two can find each other without you opening ports on your router.

The relay is **zero-knowledge**. Your devices establish end-to-end encryption directly with each
other (a Noise IK handshake using X25519 and ChaCha20-Poly1305) *before* any content is sent. The
relay only ever sees:

- a random routing token, which identifies a pairing but nothing about you, and
- opaque encrypted bytes it copies from one connection to the other.

The relay **cannot** see your screen, your keystrokes, your files, or your keys, and it cannot
decrypt the session — it holds no key material. This is enforced structurally: the relay's
forwarding code is forbidden from importing any cryptographic library, and an automated test fails
the build if that ever changes. The relay keeps no logs of your traffic content.

You do not have to use our relay at all. You can run Pocket Mac entirely on your own WiFi, or
self-host the relay yourself — it is in the same open-source repository.

## Permissions the app asks for, and why

- **Local network** (iPhone) — to discover your Mac on the same WiFi. Used only for that.
- **Camera** (iPhone) — to scan the pairing QR code your Mac displays. Images are processed on-device
  in the moment and never stored, never uploaded.
- **Accessibility and Screen Recording** (the Mac helper) — this is what actually moves your cursor,
  types your keystrokes, and captures the screen to send to your own phone. macOS requires you to
  grant these explicitly. The captured screen is encrypted and sent only to your paired device.

## Children

Pocket Mac is not directed at children and collects no personal information from anyone.

## Changes

Any change to this policy will be committed to the public repository, so the full history is
auditable.

## Contact

Questions: open an issue at <https://github.com/agbanzy/pocket-mac/issues> or email
**agbane6@gmail.com**.
