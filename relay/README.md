# Pocket Mac Relay (`relayd`)

A **zero-knowledge WSS byte-pump**. It lets an iPhone reach a Mac over the
internet when neither can expose an inbound port: both ends dial *out* to the
relay, and the relay blindly splices the two connections together.

The relay is deliberately dumb. It matches two connections by a shared
**pairing token** and forwards every byte between them verbatim. It never
terminates the end-to-end encryption the phone and Mac perform between
themselves (X25519 + ChaCha20-Poly1305), so it only ever sees the pairing token
and opaque ciphertext.

```
  iPhone  ──WSS──▶ ┌─────────┐ ◀──WSS──  Mac
                   │  relayd │
   HELLO{id} ────▶ │  match  │ ◀──── HELLO{id}
                   │  splice │
   ciphertext ───▶ │ ▲     ▼ │ ────▶ ciphertext   (forwarded verbatim)
                   └─────────┘
```

## The HELLO protocol

1. Each peer opens an outbound websocket to `wss://<relay>/ws`.
2. The **first websocket message** on each connection is the `HELLO`: the
   pairing token as a **lowercase hex string** (a random rendezvous
   identifier — **not** a key). It may be sent as a text or binary frame; only
   the bytes matter. Decoded length must be 16–64 bytes (128–512 bits); the
   canonical token is 128-bit (32 hex chars).
3. The relay reads the token under a short deadline (slowloris guard), then:
   - **First** connection with a given token → registered, waits for a partner.
   - **Second** connection with the same token → matched; the two are spliced.
   - **Third** connection with an already-matched token → rejected
     (WS close `1008 Policy Violation`, reason `pairing already active`).
   - A **lone** waiter with no partner → closed after the rendezvous timeout
     (`1008`, reason `rendezvous timeout`).
4. After the match, **every** subsequent frame from one peer is forwarded
   byte-for-byte to the other, preserving text/binary framing. The relay never
   inspects, parses, buffers unboundedly, or logs payloads.

The pairing token is minted at pairing time (e.g. shown as a QR code / short
code) and is a one-shot rendezvous address, not a secret that protects the
session. Confidentiality and integrity come entirely from the peers' own
end-to-end encryption.

## Zero-knowledge property (how it is enforced)

The blind pump lives in [`internal/session`](internal/session/session.go). By
construction it depends **only** on a tiny `Peer` interface (`Read`/`Write` of
opaque `Message{Type, Data}`) plus `context` and `time`. It imports **no**
cryptographic package and **not** the websocket library itself — the concrete
transport and its transitive crypto deps live in
[`internal/wsutil`](internal/wsutil/wsutil.go), behind the interface.

This is enforced as a test:
[`internal/session/deps_test.go`](internal/session/deps_test.go) shells out to
`go list -deps` for the pump package and fails if any dependency's import path
contains `crypto` or the websocket library. If a future change ever makes the
pump able to decrypt or inspect payloads, that test goes red.

```sh
go list -deps ./internal/session   # inspect the pump's dependency set by hand
```

## Guards

- **64 KiB** max message size (configurable) — oversize frames drop the
  connection, never buffer.
- **Per-write deadline** — a peer that stops reading is torn down rather than
  buffered without bound.
- **Keepalive ping/pong** — detects half-open connections (e.g. phone loses
  network); a missed pong tears the session down.
- **HELLO read deadline** — slowloris guard on the handshake.
- **Rendezvous timeout** — lonely waiters do not linger.
- **Per-IP connection rate limit** — a small token bucket (see
  `-trust-forwarded-for` when running behind a proxy).
- `GET /healthz` → `200 ok` for uptime checks.

## Build & test

Requires Go 1.25+.

```sh
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
go test ./... -count=1     # all tests, real loopback websockets (no mocks)
go vet ./...
gofmt -l .                 # should print nothing
go build ./cmd/relayd      # produces ./relayd
```

## Run locally (plain `ws://`)

```sh
go run ./cmd/relayd -addr :8080
# peers connect to ws://localhost:8080/ws
```

Serve TLS directly (self-signed for dev, or real cert/key files):

```sh
go run ./cmd/relayd -addr :8443 -cert server.crt -key server.key
# peers connect to wss://<host>:8443/ws
```

Key flags (all timeouts injectable; see `-h` for the full list):

| Flag | Default | Purpose |
|------|---------|---------|
| `-addr` | `:8080` | listen address |
| `-cert` / `-key` | _(none)_ | serve TLS directly when both are set |
| `-hello-timeout` | `10s` | deadline to receive the HELLO frame |
| `-rendezvous-timeout` | `30s` | how long a lone peer waits for its partner |
| `-write-timeout` | `10s` | per-message write deadline to a peer |
| `-ping-interval` | `45s` | keepalive ping period (`0` disables) |
| `-max-message-bytes` | `65536` | max websocket message size |
| `-ratelimit-burst` | `60` | per-IP connection burst (`0` disables) |
| `-trust-forwarded-for` | `false` | key rate limiting on `X-Forwarded-For` (only behind a trusted proxy) |

## Deploy: Caddy in front, `relayd` behind

In production, **do not** serve TLS from the binary. Put
[Caddy](https://caddyserver.com/) in front: it obtains and renews a Let's
Encrypt certificate automatically and reverse-proxies to `relayd` on
`localhost`. Caddy transparently proxies the websocket upgrade.

`/etc/caddy/Caddyfile`:

```caddy
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Run the relay bound to loopback and enable proxy-aware rate limiting:

```sh
relayd -addr 127.0.0.1:8080 -trust-forwarded-for
```

Peers connect to `wss://relay.example.com/ws`. TLS terminates at Caddy
(transport security); the session payload rides inside as opaque bytes that
neither Caddy nor `relayd` can read.

### Container

```sh
docker build -t pocketmac-relay .
docker run --rm -p 8080:8080 pocketmac-relay -addr :8080
```

The image is a `scratch` base with a single static binary, running as a
non-root UID.

### Cost

This workload is tiny (it forwards bytes; it holds no state beyond a map of live
pairings). A **~$4–6/mo DigitalOcean droplet** (the 512 MB–1 GB "basic" tier)
comfortably runs `relayd` + Caddy for personal / small-fleet use. Point an A/AAAA
record at the droplet, open only 80/443 in the firewall, and let Caddy handle
certificates. Scale vertically first; the relay is CPU/network-bound, not
memory-bound.
