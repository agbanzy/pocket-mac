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

## Remaining for v1.0 (phased in the plan)
Deploy the relay to a droplet (`RelayTransport`/reachability are ready — it's a URL flip); seamless
LAN↔relay path switching (`NWPathMonitor`); APNs push-to-wake + the opt-in keep-awake toggle; a
hardening pass (red-sec, `TLSChannel` contingency, sliding-window replay).

## Distribution note
The Mac helper synthesizes global input and is an Accessibility client, which the App Sandbox
forbids — so it ships as a **Developer-ID direct download**, never the Mac App Store (same reason as
Karabiner-Elements / BetterTouchTool). The iPhone app ships normally through the App Store.
