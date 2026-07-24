# Pocket Mac wire protocol

The contract every client speaks: iOS (Swift), the browser (TypeScript), and — once built — Windows
(C#) and Android (Kotlin). Frames travel inside an end-to-end encrypted session; the relay forwards
opaque bytes and never sees plaintext.

## Source of truth

`shared/conformance/vectors.json` is the **canonical table**. `shared/PocketMacKit` (Swift) is the
reference *implementation*, but it is not privileged: both it and the TypeScript port assert against
the vectors file in their own test suites.

| Port | Conformance test |
|---|---|
| Swift | `shared/PocketMacKit/Tests/PocketMacKitTests/ConformanceTests.swift` |
| TypeScript | `browser/src/protocol/conformance.test.ts` |
| Kotlin / C# | *(to be added with those ports)* |

**Changing the protocol = edit `vectors.json` first, then make every port's test pass again.** A port
that lags now fails CI instead of failing at a user's pairing screen.

### Why this exists

The TypeScript port silently drifted: its `ControlOpcode` stopped at `stopVideo = 6`, so it lacked
`runTask`/`taskEvent`/`stopTask`/`pinResponse` **and** the `TaskEventKind` enum entirely. The browser
client could not start an AI task, and a `taskEvent` arriving from the Mac hit the decoder's
`default:` branch and **threw**, killing the session. Nothing caught it because each port defined its
own tables. These vectors close that hole.

## Frame layout

Every record is `[domain: u8][opcode: u8][payload…]`. Multi-byte integers are big-endian; `string` is
the codec's length-prefixed UTF-8.

| Domain | Value |
|---|---|
| control | 0 |
| input | 1 |
| action | 2 |
| video | 3 |

## Control payloads

| Opcode | Value | Payload |
|---|---|---|
| hello | 0 | `string deviceName`, `string appVersion`, `u32 capabilities` |
| ack | 1 | `u32 seq` |
| error | 2 | `u8 code`, `string message` |
| ping | 3 | `u32 nonce` |
| pong | 4 | `u32 nonce` |
| startVideo | 5 | `u8 fps` |
| stopVideo | 6 | — |
| runTask | 7 | `string prompt`, `u8 requirePin` |
| taskEvent | 8 | `u8 kind`, `string text` |
| stopTask | 9 | — |
| pinResponse | 10 | `string pin` |

`taskEvent.kind` is a `TaskEventKind`: started 0, thinking 1, action 2, needsPin 3, done 4, error 5.

> `pinResponse`/`needsPin` remain in the wire format for compatibility with shipped clients even
> though the Mac agent now runs on single-consent autonomy and never pauses for a PIN.

## Forward compatibility

Additive changes only — never renumber an existing case. Peers must degrade rather than die:

- **Unknown domain or opcode** → a codec error the session handles, not a crash.
- **Unknown `TaskEventKind`** → treat as `thinking` (both Swift and TypeScript do this), so a newer
  Mac cannot kill an older client's session.

## Adding a port

1. Implement the tables and payloads above.
2. Add a conformance test that loads `vectors.json` and compares **whole tables** — that catches a
   missing case, an extra one, and a wrong value.
3. Keep the frame codec and the Noise handshake in separate modules; only the codec depends on these
   vectors.
