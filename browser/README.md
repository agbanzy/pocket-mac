# Pocket Mac — Browser Client

Control your Mac from any Chrome or Edge browser, over the same end-to-end encrypted,
zero-knowledge relay the iOS app uses. The relay only ever sees a routing token and opaque
ciphertext — never your screen, keystrokes, or keys.

It is a byte-for-byte port of the iOS client's security and wire layers:

| Layer | Browser (this app) | Shared source it mirrors |
|---|---|---|
| Handshake | `src/crypto/noise.ts` | `PocketMacKit/.../Noise/NoiseHandshakeIK.swift` |
| Record layer | `src/crypto/aead.ts` | `PocketMacKit/.../Crypto/AEADChannel.swift` |
| Wire codec | `src/protocol/frames.ts` | `PocketMacKit/.../Codec/FrameCodec.swift` |
| Video reassembly | `src/protocol/video.ts` | `PocketMacKit/.../Protocol/VideoFrame.swift` |
| Relay transport | `src/transport/relay.ts` | `PocketMacKit/.../Session/RelayTransport.swift` |
| Session controller | `src/session/connection.ts` | `ios/.../Connection/ConnectionController.swift` |
| H.264 decode | `src/video/decoder.ts` | WebCodecs `VideoDecoder` (Mac encodes H.264 High, Annex-B) |
| Input | `src/input/controls.ts` | `mac/.../Input/CGEventTranslator.swift` |

Conformance is enforced by `npm test` (57 tests): the same Noise IK loopback, AEAD replay/tamper
rejection, frame round-trips, and pairing/URL parsing as the Swift kit.

## Requirements

- A Chromium browser (Chrome / Edge / Brave) — the screen decode uses **WebCodecs**, which Safari
  and Firefox do not yet fully support. The client detects this and tells you if it is unavailable.

## Develop

```bash
npm install
npm run dev      # vite dev server on http://localhost:5174
npm test         # vitest conformance suite (57 tests)
npm run build    # tsc --noEmit && vite build → dist/
```

## Pair a browser

1. Open **Pocket Mac** on your Mac and choose **Pair a browser** — it shows a `pocketmac://pair?…` link.
2. Paste that link into the web client and press **Pair & Connect**.
3. Confirm the 6-digit SAS code matches on both ends.

The browser generates its own long-term X25519 identity (persisted in `localStorage`) and is
authorized by the Mac the same way the phone is — by its static public key, admitted once during the
Mac's time-bounded pairing window, then remembered for reconnects. Use **Reset identity** to forget it.

> Security note: `localStorage` is readable by any script on this origin — a browser has no secure
> enclave like the phone's keychain. Treat the machine/profile running this client as trusted. The
> relay still never sees your keys; end-to-end encryption is unaffected.

## Controls

- **Move / click** — move the mouse over the screen; left / right / middle click all map through.
- **Right-click** — opens the Mac's context menu (the browser's own menu is suppressed).
- **Scroll** — the wheel scrolls the focused Mac app.
- **Type** — printable text streams as Unicode; **⌘/⌃/⌥ shortcuts**, arrows, Return, Tab, Delete map to
  macOS keycodes.
- **Fullscreen** — the ⛶ button.

## Deploy (static bundle)

`npm run build` emits a self-contained `dist/` (relative asset paths, so it hosts under any path).
On the Pocket Mac droplet it is served by Caddy at `pocketpc.innoedgetech.com/app`:

```bash
scp -r dist/. root@<droplet>:/var/www/pocketmac/app/
```

Any static host works (GitHub Pages, Cloudflare Pages, `node proxy.mjs`). The default relay endpoint
is baked in and overridable in the client's **Advanced** panel or via `?relay=wss://…`.
