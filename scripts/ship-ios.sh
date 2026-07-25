#!/usr/bin/env bash
# Build, sign and upload the iOS app to TestFlight without needing an Xcode account.
#
# Why this exists
# ---------------
# `xcodebuild archive` with automatic signing resolves the team through whatever Apple ID is signed
# into Xcode. That is invisible state: it lapses, and when it does every release fails with
#   error: No Account for Team "…"
# with nothing in the repo having changed. Manual signing is not an escape either — the App Store
# profile Apple issues is Xcode-managed, and xcodebuild refuses to use a managed profile under
# manual signing.
#
# So this script sidesteps signing during the build entirely: archive unsigned, then codesign the
# .app directly against the profile and certificate, package the .ipa by hand, and upload with an
# App Store Connect API key. Nothing here reads Xcode's account state.
#
# Usage:  scripts/ship-ios.sh [--bump] [--no-upload]
#           --bump       increment CURRENT_PROJECT_VERSION first (App Store Connect rejects a build
#                        number it has already seen, so a release almost always wants this)
#           --no-upload  build, sign and validate, but stop before uploading
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/ship-ios.xcarchive"
STAGE="$BUILD/ship-ios"
TEAM="${POCKETMAC_TEAM:-JB94NKM5A6}"
BUNDLE_ID="${POCKETMAC_BUNDLE_ID:-com.innoedge.pocketmac}"

# App Store Connect API key. Locations only — the key itself never appears here.
API_KEY_ID="${POCKETMAC_ASC_KEY_ID:-882J3MBG6L}"
API_ISSUER="${POCKETMAC_ASC_ISSUER:-bd2dd7d7-67b6-40d7-b04f-6583bcf9e23e}"

UPLOAD=1
BUMP=0
for arg in "$@"; do
  case "$arg" in
    --no-upload) UPLOAD=0 ;;
    --bump) BUMP=1 ;;
    *) printf 'error: unknown argument %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say() { printf '› %s\n' "$1"; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --- 1. Pick the signing identity ------------------------------------------------------------
# There can be more than one "Apple Distribution" certificate for the same team, and an expired or
# revoked one is still returned by find-identity. Selecting by name would be a coin flip, so pin the
# SHA-1 of a valid one: `-v` lists only identities that currently validate for code signing.
say "Finding a valid Apple Distribution identity for ${TEAM}…"
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Apple Distribution" | grep "$TEAM" | grep -v CSSMERR \
  | head -1 | awk '{print $2}')
[ -n "$IDENTITY" ] || die "no valid Apple Distribution identity for team $TEAM in the keychain"
say "Using identity $IDENTITY"

# --- 2. Find the App Store provisioning profile ----------------------------------------------
# Match on the entitlement rather than the filename: profiles are stored under opaque UUID names,
# and a Distribution profile is the one whose application-identifier is <team>.<bundle id> and which
# has no provisioned devices (a development profile lists them).
say "Locating an App Store profile for ${BUNDLE_ID}…"
PROFILE=""
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; do
  [ -e "$f" ] || continue
  plist=$(security cms -D -i "$f" 2>/dev/null) || continue
  appid=$(printf '%s' "$plist" | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)
  [ "$appid" = "$TEAM.$BUNDLE_ID" ] || continue
  # ProvisionedDevices present => development/ad-hoc, not App Store.
  if printf '%s' "$plist" | plutil -extract ProvisionedDevices raw - >/dev/null 2>&1; then continue; fi
  PROFILE="$f"; break
done
[ -n "$PROFILE" ] || die "no App Store provisioning profile for $TEAM.$BUNDLE_ID — open Xcode once to download it"
say "Using profile $(basename "$PROFILE")"

# --- 3. Archive unsigned ----------------------------------------------------------------------
if [ "$BUMP" -eq 1 ]; then
  CUR=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' "$ROOT/ios/project.yml" | head -1)
  [ -n "$CUR" ] || die "could not read CURRENT_PROJECT_VERSION from ios/project.yml"
  NEXT=$((CUR + 1))
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CUR\"/CURRENT_PROJECT_VERSION: \"$NEXT\"/" "$ROOT/ios/project.yml"
  say "Bumped build $CUR → $NEXT"
fi

say "Generating project…"
( cd "$ROOT/ios" && xcodegen generate --spec project.yml >/dev/null )

say "Archiving unsigned…"
rm -rf "$ARCHIVE"
xcodebuild -project "$ROOT/ios/PocketMac.xcodeproj" -scheme PocketMacApp \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" -derivedDataPath "$BUILD/dd-ship-ios" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  archive >"$BUILD/ship-ios-archive.log" 2>&1 \
  || { tail -30 "$BUILD/ship-ios-archive.log"; die "archive failed (full log: $BUILD/ship-ios-archive.log)"; }

APP_SRC="$ARCHIVE/Products/Applications/PocketMac.app"
[ -d "$APP_SRC" ] || die "no app in the archive at $APP_SRC"
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_SRC/Info.plist")
say "Archived build $BUILD_NUM"

# --- 4. Sign ----------------------------------------------------------------------------------
# The entitlements must come from the profile. Inventing them risks claiming something the profile
# does not grant, which App Store Connect rejects after upload rather than at signing time.
rm -rf "$STAGE"; mkdir -p "$STAGE/Payload"
cp -R "$APP_SRC" "$STAGE/Payload/"
APP="$STAGE/Payload/PocketMac.app"
cp "$PROFILE" "$APP/embedded.mobileprovision"
security cms -D -i "$PROFILE" > "$STAGE/profile.plist"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$STAGE/profile.plist" > "$STAGE/entitlements.plist"

# Sign inside-out: nested code first, then the bundle. Signing only the outer bundle leaves nested
# Mach-O with a stale signature and the app is rejected at install.
say "Signing nested code…"
while IFS= read -r nested; do
  [ -n "$nested" ] || continue
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$nested"
done < <(find "$APP" \( -type d -name "*.framework" -o -type d -name "*.appex" -o -type f -name "*.dylib" \))

say "Signing app…"
codesign --force --timestamp --sign "$IDENTITY" --entitlements "$STAGE/entitlements.plist" "$APP"
codesign --verify --strict "$APP" || die "signature verification failed"

IPA="$BUILD/PocketMac-$BUILD_NUM.ipa"
rm -f "$IPA"
( cd "$STAGE" && zip -qry "$IPA" Payload )
say "Packaged $IPA"

# --- 5. Validate, then upload -----------------------------------------------------------------
# Validate first: it catches the same problems as upload but without consuming a build number.
say "Validating…"
xcrun altool --validate-app -f "$IPA" -t ios \
  --apiKey "$API_KEY_ID" --apiIssuer "$API_ISSUER" \
  || die "validation failed — not uploading"

if [ "$UPLOAD" -eq 0 ]; then
  say "--no-upload given; stopping with a validated $IPA"
  exit 0
fi

say "Uploading to TestFlight…"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$API_KEY_ID" --apiIssuer "$API_ISSUER" \
  || die "upload failed"

say "Uploaded build $BUILD_NUM. It appears in TestFlight once processing finishes."
