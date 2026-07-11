# ADR 0003 — Session crypto: Noise IK on CryptoKit

Status: accepted · Date: 2026-07-11

## Context
Pocket Mac exposes a control channel that types into a Mac over the internet. The session must be
keyed to **device identity, not network path**, so LAN and the relay behave identically and the
relay stays zero-knowledge. The design doc's primary was Noise IK; TLS 1.3 with pinned keys was
named an acceptable substitute.

## Decision
Ship a **Noise `IK` handshake built on Apple's CryptoKit primitives** — X25519 identity keys,
HKDF-SHA256 key schedule, ChaCha20-Poly1305 — then per-frame AEAD with a 64-bit monotonic counter
nonce + replay rejection. Abstract it behind `SessionHandshaking` / `SecureChannel` seams.

## Alternatives rejected
- **TLS 1.3 + pinned self-signed certs.** Lowest crypto risk and Apple-audited, but a poor fit:
  X25519 keys cannot sign X.509 certs (forces an Ed25519 identity + on-device cert minting, for
  which there is no first-party Swift API); TLS's record AEAD makes §6's per-frame AEAD dead code;
  and the zero-knowledge-relay handshake would have to be re-solved at the app layer later — i.e.
  build the security layer twice. Kept as a `TLSChannel` contingency behind the `SecureChannel` seam.
- **Noise IK via a third-party Swift library.** No mature, audited, Swift-6-native Noise IK library
  exists; libsodium provides primitives, not the IK pattern. No advantage over CryptoKit, plus
  dependency rot on the most security-critical code.
- **Hand-rolled primitives.** Never — only the *pattern* is assembled here; every primitive is
  CryptoKit's.

## Honest corrections carried into the code
- **X25519 cannot reside in the Secure Enclave** (SE is P-256 only). The design doc's "Secure
  Enclave / Keychain" resolves to Keychain (`WhenUnlockedThisDeviceOnly`, non-synchronizable).
  Hardware binding later means adding a P-256 SE attestation key *alongside* the X25519 DH key.

## Consequences
- The exact handshake that carries to the relay is de-risked at Milestone 0.
- Verified by unit tests: both sides derive matching keys that interoperate through the record
  layer; MITM (wrong pinned static) rejected; wrong-PIN (prologue mismatch) rejected; tamper rejected.
- Follow-up hardening (Phase 12): tighten to full IK identity-hiding 1-RTT; sliding-window replay
  bitmap for the reordering-capable relay path; cross-validate against canonical Noise test vectors.
