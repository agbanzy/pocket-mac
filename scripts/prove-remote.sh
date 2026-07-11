#!/usr/bin/env bash
# Proves the full remote path locally: iPhone(probe) -> relay -> REAL Mac helper.
# Starts a local relay, launches the helper pointed at it (--relay) in pairing mode (--auto-pair),
# then runs the probe THROUGH the relay (--via-relay). No cloud, no LAN discovery - the phone and Mac
# meet only on the relay, exactly as they would over the internet.
set -eo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=18080
RELAY_WS="ws://127.0.0.1:$PORT/ws"

echo "> Building relay, helper, probe..."
( cd "$ROOT/relay" && go build -o /tmp/pocketmac-relayd ./cmd/relayd )
"$ROOT/scripts/build-mac.sh" >/dev/null
( cd "$ROOT/probe" && swift build >/dev/null )

echo "> Cleaning up any prior run..."
pkill -f PocketMacHelper 2>/dev/null || true
pkill -f pocketmac-relayd 2>/dev/null || true
rm -f "$HOME/Library/Application Support/PocketMac/pairing.url"
sleep 1

echo "> Starting relay on 127.0.0.1:$PORT..."
/tmp/pocketmac-relayd -addr "127.0.0.1:$PORT" &
RELAY_PID=$!
trap 'kill $RELAY_PID 2>/dev/null || true; pkill -f PocketMacHelper 2>/dev/null || true' EXIT
sleep 1

echo "> Launching Mac helper (--relay $RELAY_WS --auto-pair)..."
open "$ROOT/build/mac/Build/Products/Debug/PocketMacHelper.app" --args --relay "$RELAY_WS" --auto-pair
sleep 4

echo "> Running probe THROUGH the relay (--via-relay)..."
"$ROOT/probe/.build/debug/PocketMacProbe" --via-relay "$RELAY_WS"
