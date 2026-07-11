#!/usr/bin/env bash
# Proves the remote-path transport interop locally: starts the real Go relay, then runs the probe's
# --relay-selftest (two RelayTransport peers rendezvous through the relay, handshake, and exchange
# encrypted frames). No droplet or network needed - just the relay binary + Swift client.
set -eo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=18080

echo "> Building relay + probe..."
( cd "$ROOT/relay" && go build -o /tmp/pocketmac-relayd ./cmd/relayd )
( cd "$ROOT/probe" && swift build >/dev/null )

echo "> Starting relay on 127.0.0.1:$PORT..."
/tmp/pocketmac-relayd -addr "127.0.0.1:$PORT" &
RELAY_PID=$!
trap 'kill $RELAY_PID 2>/dev/null || true' EXIT
sleep 1

echo "> Running relay round-trip self-test..."
"$ROOT/probe/.build/debug/PocketMacProbe" --relay-selftest "ws://127.0.0.1:$PORT/ws"
