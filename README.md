# Pocket Mac

Control your Mac from your iPhone — trackpad, keyboard, media keys, and a customizable grid of
one-tap action tiles — on the same WiFi and (v1.0) over the internet, through a zero-knowledge
relay. **No screen streaming**: a fast, secure control channel, not a remote desktop.

## Layout
| Path | What |
|---|---|
| `shared/PocketMacKit/` | Cross-platform core: protocol, codec, Noise IK crypto, `SecureSession`, discovery. Fully unit-tested. |
| `mac/PocketMacHelper/` | Menu-bar helper (`CGEvent` input synthesis, Bonjour, responder handshake). |
| `ios/PocketMac/` | SwiftUI iPhone app (trackpad, pairing, tile deck, initiator handshake). |
| `relay/` | Go zero-knowledge WSS byte-forwarder (built now, deployed in v1.0). |
| `probe/PocketMacProbe/` | Pure-Swift CLI E2E harness: discover → pair → drive → assert. |
| `docs/`, `specs/` | Architecture, security model, ADRs, and BDD acceptance scenarios. |

## Prove it (Milestone 0 — LAN)
```bash
./scripts/prove-m0.sh
```
Runs the kit unit tests, the relay integration tests, builds + stably-signs the helper, launches it,
and runs the probe against it over a real Bonjour socket. The one manual step is granting the helper
**Accessibility** (System Settings → Privacy & Security → Accessibility) — until then the probe
reports `WARN`: the encrypted session works, but `CGEventPost` is a no-op without the grant.

## Status
- **PocketMacKit** — complete, `swift test` green (37 tests).
- **Mac helper** + **probe** — build clean; live LAN proof works end-to-end (discover → Noise IK
  handshake → encrypted session → frame delivery); cursor movement pending the Accessibility grant.
- **Go relay**, **iOS app** — see `relay/README.md` and `ios/`.
- **v1.0 remote path** (relay deploy, `RelayTransport`, path switching, APNs wake) — phased in
  `~/.claude/plans/…`; the crypto session is already path-agnostic so the relay drops in cleanly.

## Distribution note
The Mac helper synthesizes global input and is an Accessibility client, which the App Sandbox
forbids — so it ships as a **Developer-ID direct download**, never the Mac App Store (same reason as
Karabiner-Elements / BetterTouchTool). The iPhone app ships normally through the App Store.
