#!/usr/bin/env bash
# Milestone-0 "prove it" runbook. Runs the deterministic gates, then the live LAN proof.
#
#   [auto] kit unit tests        — codec / AEAD / replay / handshake / pairing
#   [auto] relay integration     — blind forwarding / zero-knowledge / no-cross
#   [auto] build + sign helper    — stable signature for a persistent Accessibility grant
#   [live] helper + probe         — discover → pair → encrypted session → drive the cursor
#
# The ONE manual step is granting Accessibility to the helper (a security setting only you can
# approve). Until then the probe reports WARN: the session works, but CGEventPost is a no-op.
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "══ 1/4  Kit unit tests [auto] ══"
( cd "$ROOT/shared/PocketMacKit" && swift test 2>&1 | tail -1 )

echo "══ 2/4  Relay integration tests [auto] ══"
if [ -f "$ROOT/relay/go.mod" ]; then
  ( cd "$ROOT/relay" && go test ./... -count=1 2>&1 | tail -3 )
else
  echo "   (relay/go.mod not present yet — skipping)"
fi

echo "══ 3/4  Build + sign helper [auto] ══"
"$ROOT/scripts/build-mac.sh"

echo "══ 4/4  Live LAN proof [live] ══"
APP="$ROOT/build/mac/Build/Products/Debug/PocketMacHelper.app"
rm -f "$HOME/Library/Application Support/PocketMac/pairing.url"
pkill -f PocketMacHelper 2>/dev/null || true
sleep 1
echo "   launching helper (--auto-pair)…"
open "$APP" --args --auto-pair
sleep 4
echo "   building + running probe…"
( cd "$ROOT/probe" && swift build >/dev/null && ./.build/debug/PocketMacProbe )

cat <<'EOF'

────────────────────────────────────────────────────────────
If the probe said WARN (cursor Δx=0): grant Accessibility once —
  System Settings → Privacy & Security → Accessibility → enable PocketMacHelper
then re-run:  ./probe/.build/debug/PocketMacProbe --assert
The cursor will move and the probe will PASS.
────────────────────────────────────────────────────────────
EOF
