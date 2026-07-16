# Pocket Mac

See and control your Mac from your iPhone or any Chrome/Edge browser — **live screen streaming** with
tap-to-click, keyboard, trackpad, and a customizable grid of one-tap action tiles — on the same WiFi
or anywhere over the internet, through a zero-knowledge relay. No port-forwarding.

**Download:** [Mac helper (notarized .dmg)](https://github.com/agbanzy/pocket-mac/releases/latest) ·
[Web client](https://pocketpc.innoedgetech.com/app) · iPhone app coming to the App Store.

## Layout
| Path | What |
|---|---|
| `shared/PocketMacKit/` | Cross-platform core: protocol, codec, Noise IK crypto, `SecureSession`, discovery. Fully unit-tested. |
| `mac/PocketMacHelper/` | Menu-bar helper (`CGEvent` input synthesis, Bonjour, responder handshake). |
| `ios/PocketMac/` | SwiftUI iPhone app (trackpad, pairing, tile deck, initiator handshake). |
| `relay/` | Go zero-knowledge WSS byte-forwarder (built now, deployed in v1.0). |
| `probe/PocketMacProbe/` | Pure-Swift CLI E2E harness: discover → pair → drive → assert. |
| `docs/`, `specs/` | Architecture, security model, ADRs, and BDD acceptance scenarios. |

## Prove it
```bash
./scripts/prove-m0.sh        # LAN: kit tests + relay tests + helper + probe over Bonjour
./scripts/relay-roundtrip.sh # RelayTransport <-> Go relay <-> RelayTransport (Swift/Go interop)
./scripts/prove-remote.sh    # REMOTE: probe -> relay -> real helper (no LAN, no cloud)
```
Each builds what it needs and runs a live proof. The one manual step is granting the helper
**Accessibility** (System Settings → Privacy & Security → Accessibility) — until then the probe
reports `WARN`: the encrypted session establishes and delivers frames, but `CGEventPost` is a no-op
without the grant. Grant it, then `./probe/.build/debug/PocketMacProbe --assert` moves the cursor.

## Status — all four components built and verified
- **PocketMacKit** — complete, `swift test` green (37 tests): codec, Noise IK, AEAD, replay/tamper,
  MITM + wrong-PIN rejection.
- **Mac helper** — builds + stably signs; advertises on LAN and holds an outbound **relay responder**
  when `--relay` is set. Live proof: real helper reached over **both** LAN and relay.
- **Go relay** — `go test` green under `-race`; zero-knowledge enforced by a `go list -deps` test.
- **iOS app** — builds for the iOS 26.5 Simulator, launches, pairs via deep link; LAN + `.relay`
  connection arms wired.
- **Both transport paths proven** end-to-end against the real helper (`prove-remote.sh`,
  `relay-roundtrip.sh`). Cursor movement pends the Accessibility grant.

## Deployed
The zero-knowledge relay is **live** at `wss://165.227.155.134.sslip.io/ws` (DigitalOcean fra1,
Caddy + Let's Encrypt TLS, no domain). A session has been proven **iPhone→internet→relay→Mac**
end-to-end against it. See `relay/deploy/`. The iOS app defaults to this URL; the helper takes `--relay`.

## Remaining for v1.0 (phased in the plan)
APNs push-to-wake + the opt-in keep-awake toggle (needs an APNs key); optional deeper hardening
(`TLSChannel` contingency, sliding-window replay). The critical security pass (pairing-window
auth-bypass, revoke-kills-session, handshake throttle) is **done** — see `docs/security-model.md`.

## Distribution note
The Mac helper synthesizes global input and is an Accessibility client, which the App Sandbox
forbids — so it ships as a **Developer-ID direct download**, never the Mac App Store (same reason as
Karabiner-Elements / BetterTouchTool). The iPhone app ships normally through the App Store.
