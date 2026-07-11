# Pocket Mac — Architecture

Control your Mac from your iPhone — trackpad, keyboard, media keys, action tiles — on WiFi and
(v1.0) over the internet. **No screen streaming**: a fast, secure control channel, not a remote
desktop.

## Components
- **`shared/PocketMacKit`** — the cross-platform (iOS + macOS) core: wire protocol + codec, crypto
  (X25519 identity, Noise IK handshake, ChaCha20-Poly1305 record layer, replay window), pairing,
  the path-agnostic `SecureSession`, transports, the peer store, and Bonjour discovery. One wire
  protocol, one crypto core, one security boundary. Contains **no** CGEvent / UIKit code.
- **`mac/PocketMacHelper`** — a menu-bar (`LSUIElement`) LaunchAgent that advertises over Bonjour,
  runs the Noise **responder** handshake (accept-only-paired), and turns decrypted frames into real
  input via `CGEvent` + media keys, plus app/shortcut/system actions. Hardened Runtime on, App
  Sandbox off, Developer-ID direct download (never the Mac App Store).
- **`ios/PocketMac`** — the SwiftUI iPhone app: Bonjour discovery, QR/PIN pairing, a UIKit-backed
  trackpad (coalesced/predicted touch), a tile deck, and the Noise **initiator** side.
- **`relay/`** — a Go zero-knowledge WSS byte-forwarder: matches two connections by a random
  rendezvous token and blind-copies opaque ciphertext. Built now; deployed in v1.0.
- **`probe/PocketMacProbe`** — a pure-Swift CLI that discovers, pairs, drives, and asserts the real
  cursor moved. The CI-grade end-to-end harness.

## The one pipeline (LAN and relay identical)
```
send:    Frame → FrameCodec.encode → AEADChannel.seal([counter‖ct‖tag]) → Transport.send (len-prefixed)
receive: Transport.receive → AEADChannel.open (ReplayWindow) → FrameCodec.decode → Frame
```
`SecureSession` (an actor) composes codec + `SecureChannel` + `Transport`. The transport is the only
thing that differs between LAN (`NWConnectionTransport` over a Bonjour-discovered `NWConnection`) and
relay (`RelayTransport` over WSS) — because the crypto session is keyed to device identity, a
LAN↔relay switch is just a re-handshake.

## Trust & pairing
Each device holds a long-term X25519 identity keypair (`PeerID = SHA256(pubkey)`). Pairing is
out-of-band: the Mac shows a `pocketmac://pair?…` URL as a QR (device) or deep link (Simulator),
carrying its public key + a 6-digit SAS. The phone (initiator) already knows the Mac's static key;
the Mac (responder) authorizes the phone against its peer store and admits new peers only during a
pairing window. Revocation = delete/flag the peer's key.

See `docs/security-model.md` and `docs/decisions/` for the crypto rationale and the transport,
daemon, and packaging decisions.
