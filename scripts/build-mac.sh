#!/usr/bin/env bash
# Build + stably-sign the Mac helper so the Accessibility (TCC) grant persists across rebuilds.
# Signing with the same Apple Development identity every time keeps the code signature (and thus the
# TCC grant) stable — ad-hoc signing would re-prompt on every build.
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Default to Developer ID, because that is what the *installed* helper is signed with. macOS keys the
# Accessibility and Screen Recording grants to the code signature, so replacing /Applications with a
# bundle signed by a different identity silently revokes both — and re-granting them needs the user's
# password in System Settings, which no script can do. Matching the installed identity keeps the
# grants. Override only if you know the installed copy was signed the same way.
IDENTITY="${POCKETMAC_SIGN_IDENTITY:-Developer ID Application: INNOEDGE TECHNOLOGIES LIMITED (JB94NKM5A6)}"
DERIVED="$ROOT/build/mac"
APP="$DERIVED/Build/Products/Debug/PocketMacHelper.app"

echo "› Generating Xcode project…"
( cd "$ROOT/mac" && xcodegen generate --spec project.yml >/dev/null )

echo "› Building helper…"
xcodebuild -project "$ROOT/mac/PocketMacHelper.xcodeproj" -scheme PocketMacHelper \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build >/dev/null

echo "› Signing with: $IDENTITY"
# Sign inside-out: nested Mach-O (the Debug build's app dylib) first, then the bundle. Signing only
# the top level would leave the nested dylib on a different Team ID and dyld would refuse to load it.
while IFS= read -r nested; do
  codesign --force --sign "$IDENTITY" --options runtime "$nested"
done < <(find "$APP/Contents" -type f \( -name "*.dylib" -o -name "*.framework" \))
codesign --force --sign "$IDENTITY" --options runtime \
  --entitlements "$ROOT/mac/PocketMacHelper/Resources/PocketMacHelper.entitlements" \
  "$APP"

codesign --verify --strict "$APP"
echo "✓ Signed helper: $APP"

# Warn before this build can silently cost the user their TCC grants. macOS keys Accessibility and
# Screen Recording to the *designated requirement*, so copying a bundle signed differently from the
# installed one revokes both, and only the user can restore them (System Settings, password).
INSTALLED="/Applications/PocketMacHelper.app"
if [ -d "$INSTALLED" ]; then
  dr_of() { codesign -dr - "$1" 2>&1 | sed -n 's/^designated => //p'; }
  if [ "$(dr_of "$INSTALLED")" != "$(dr_of "$APP")" ]; then
    cat >&2 <<EOF

⚠️  This build's code signature does NOT match the installed helper.

    installed: $(dr_of "$INSTALLED")
    this build: $(dr_of "$APP")

    Replacing /Applications/PocketMacHelper.app with this build will RESET its Accessibility and
    Screen Recording permissions, and re-granting them requires your password in System Settings.

    To keep the grants, rebuild with the identity the installed copy uses:
      POCKETMAC_SIGN_IDENTITY="<that identity>" scripts/build-mac.sh
EOF
  fi
fi
