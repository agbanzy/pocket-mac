# Pocket Mac — Security Model

A channel that types into a Mac over the internet is a serious surface. The controls below are
ship-blockers, not features.

## Identity & pairing
- Each device holds a long-term **X25519** identity keypair; `PeerID = SHA256(publicKey)`.
- Private keys live in the Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
  non-synchronizable). (X25519 can't live in the Secure Enclave — see ADR 0003.)
- Pairing is **out-of-band**: the Mac's public key travels over the trusted visual channel (QR) or a
  deep link, plus a 6-digit **SAS** bound into the handshake prologue so a wrong PIN fails the
  handshake's first AEAD open.

## Session
- **Noise `IK`** handshake (mutual auth, forward secrecy). The initiator knows the responder's static
  key from pairing; the responder authenticates the initiator's static and admits it only if paired
  and not revoked (new peers only during an explicit pairing window).
- Per-frame **ChaCha20-Poly1305** AEAD under a 64-bit monotonic counter nonce. The receiver rejects
  any non-increasing counter (**replay** protection) and any failed tag (**tamper** protection).
- Inbound events are **rate-limited** on the Mac as a floor against a runaway/hostile client.

## Relay (v1.0)
- **Zero-knowledge by construction**: the relay matches two connections by a random rendezvous token
  and blind-copies opaque ciphertext. It never terminates the E2E crypto — its forwarding package
  imports no crypto and never inspects payloads (enforced by a test). Compromise yields ciphertext +
  metadata (sizes, timing, token linkage) only, never plaintext or forged events.

## Threat model
| Adversary | Outcome |
|---|---|
| Compromised relay | Can drop/delay/observe metadata; **cannot** read or forge events (forged frames fail AEAD). Worst case: denial of service. |
| Wire MITM | Blocked by Noise static-key authentication + pairing-time SAS binding. |
| Unpaired / revoked device | Refused before handshake message 2. |
| Stolen, unlocked phone | The real residual risk — mitigated by per-session biometric re-auth (app) and Mac-side **revocation** (delete the peer's key; its handshakes then fail immediately). |

## Verified today (unit tests, `swift test`)
Matching-key agreement · MITM (wrong pinned static) rejected · wrong-PIN rejected · replay rejected ·
tamper rejected · unpaired/revoked refused · malformed frames throw (never trap).
