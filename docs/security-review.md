# Security Review — 2026-07-12

An adversarial review of the auth/crypto/relay/helper surfaces (the "types into a Mac over the
internet" surface — the Remote-Mouse-CVE cautionary tale). Crypto core (Noise IK, AEAD, replay,
zero-knowledge relay, key handling) was audited **sound**. All findings were in the application-layer
pairing gate. Status below.

## Fixed
- **CRITICAL — pairing-window auth bypass.** Was: relay pairing took no PIN, the window never
  expired, a relay pairing didn't close the LAN window, and admission wasn't atomic (TOCTOU). Now:
  the window is **time-bounded** (120 s), **single-admission** via one atomic compare-and-set shared
  across LAN + relay, **SAS-bound on both transports**, and **uniformly closed** on any success.
  Verified: window open → device pairs; window closed → a second device with the exact pairing URL is
  refused at the handshake.
- **HIGH — revoke now terminates the live session.** `SessionAccepter` tracks active sessions by
  `PeerID`; `revoke()` cancels the receive loop + closes the transport immediately, not just future
  handshakes.
- **HIGH — handshake-attempt throttle** added (~2/s, burst 10), distinct from the post-auth input
  limiter — bounds SAS brute-force / connection floods.
- **LOW — `--auto-pair`** is now compiled out of release builds (`#if DEBUG`).

## Accepted / deferred (with rationale)
- **`ActionExecutor` breadth (launchApp/runShortcut/keystrokes) = full local-user control.** By
  design for a remote keyboard/mouse; process spawning is injection-safe (`Process.arguments`, no
  shell). The security boundary is the pairing gate, which is why the fixes above matter most. A
  per-tile allowlist is a possible future tightening.
- **Input `RateLimiter` (600/s) is a floor, not an anti-abuse ceiling** against an *already-paired*
  malicious peer. Acceptable: pairing already implies full trust.
- **Persistent per-peer rendezvous token → targeted relay DoS** (not impersonation — the authorize
  still requires the peer's key). Sound boundary; rotating tokens per session is a future hardening.
- **`BinaryWriter.writeString` truncates an oversized length prefix** instead of throwing. Confirmed
  **unreachable** today (the frame-level `maxPayloadSize` check rejects first); latent footgun to
  harden when multi-variable-length frames appear.
- **Plaintext pairing-handoff file** (`~/Library/Application Support/PocketMac/pairing.url`) — dev/CI
  aid; same-user-readable only, deleted on close, and now bounded by the 120 s window.

## Future design hardening
Deliver the SAS out-of-band from the token (not both in one QR) so it's a true second factor;
per-session rendezvous tokens; `TLSChannel` contingency behind the `SecureChannel` seam.
