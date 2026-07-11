#!/usr/bin/env bash
# Build + stably-sign the Mac helper so the Accessibility (TCC) grant persists across rebuilds.
# Signing with the same Apple Development identity every time keeps the code signature (and thus the
# TCC grant) stable — ad-hoc signing would re-prompt on every build.
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${POCKETMAC_SIGN_IDENTITY:-Apple Development: GODWIN AGBANE (7T7BJT2AU7)}"
DERIVED="$ROOT/build/mac"
APP="$DERIVED/Build/Products/Debug/PocketMacHelper.app"

echo "› Generating Xcode project…"
( cd "$ROOT/mac" && xcodegen generate --spec project.yml >/dev/null )

echo "› Building helper…"
xcodebuild -project "$ROOT/mac/PocketMacHelper.xcodeproj" -scheme PocketMacHelper \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build >/dev/null

echo "› Signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" --options runtime \
  --entitlements "$ROOT/mac/PocketMacHelper/Resources/PocketMacHelper.entitlements" \
  "$APP"

codesign --verify --strict "$APP"
echo "✓ Signed helper: $APP"
