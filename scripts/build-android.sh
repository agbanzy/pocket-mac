#!/usr/bin/env bash
# Cross-compile the shared Rust agent into an Android .so.
#
# The NDK ships its own clang per API level, and cargo will not find it on its own: the C
# dependencies (TLS, ring) need CC/AR pointed at the NDK toolchain and the linker set per target.
# That wiring is the whole reason this script exists — the cargo invocation itself is one line.
#
# Usage:  scripts/build-android.sh [abi ...]        default: arm64-v8a
#         scripts/build-android.sh arm64-v8a x86_64
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="${POCKETMAC_ANDROID_API:-24}"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"

say() { printf '› %s\n' "$1"; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# Pick the newest installed NDK rather than pinning one, so this keeps working after an SDK update.
[ -d "$SDK/ndk" ] || die "no NDK under $SDK/ndk — install one via Android Studio or sdkmanager"
NDK_VERSION="$(ls "$SDK/ndk" | sort -V | tail -1)"
TOOLCHAIN="$SDK/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/darwin-x86_64/bin"
[ -d "$TOOLCHAIN" ] || die "NDK $NDK_VERSION has no darwin-x86_64 toolchain at $TOOLCHAIN"
say "Using NDK $NDK_VERSION (API $API)"

# ABI → rust target triple → the NDK's clang prefix (which is the triple again, except for armv7,
# where the toolchain is armv7a-* while rust calls it armv7-*).
abi_target() {
  case "$1" in
    arm64-v8a)   echo "aarch64-linux-android aarch64-linux-android" ;;
    x86_64)      echo "x86_64-linux-android x86_64-linux-android" ;;
    armeabi-v7a) echo "armv7-linux-androideabi armv7a-linux-androideabi" ;;
    *) die "unknown ABI '$1' (use arm64-v8a, x86_64, or armeabi-v7a)" ;;
  esac
}

ABIS=("$@")
[ ${#ABIS[@]} -eq 0 ] && ABIS=(arm64-v8a)

for abi in "${ABIS[@]}"; do
  read -r TRIPLE CLANG_PREFIX <<<"$(abi_target "$abi")"
  rustup target add "$TRIPLE" >/dev/null 2>&1 || true

  CLANG="$TOOLCHAIN/${CLANG_PREFIX}${API}-clang"
  [ -x "$CLANG" ] || die "no clang for $abi at $CLANG"

  # cargo reads these as <VAR>_<triple with underscores>.
  UPPER="$(echo "$TRIPLE" | tr 'a-z-' 'A-Z_')"
  ENVVAR="$(echo "$TRIPLE" | tr '-' '_')"

  say "Building $abi ($TRIPLE)…"
  env \
    "CC_${ENVVAR}=$CLANG" \
    "AR_${ENVVAR}=$TOOLCHAIN/llvm-ar" \
    "CARGO_TARGET_${UPPER}_LINKER=$CLANG" \
    cargo build -p agent-jni --target "$TRIPLE" --release

  SO="$ROOT/target/$TRIPLE/release/libagent_jni.so"
  [ -f "$SO" ] || die "expected $SO"

  # Prove the JNI entry points are actually exported — a .so that builds but exports nothing fails
  # at runtime with UnsatisfiedLinkError, which is a much worse place to find out.
  EXPORTS=$("$TOOLCHAIN/llvm-nm" -D --defined-only "$SO" | grep -c '^.* T Java_com_innoedge_pocketmac_' || true)
  [ "$EXPORTS" -ge 2 ] || die "$abi built but exports $EXPORTS JNI symbols (expected runTask + cancel)"

  OUT="$ROOT/build/android/$abi"
  mkdir -p "$OUT"
  cp "$SO" "$OUT/"
  say "✓ $abi → $OUT/libagent_jni.so ($EXPORTS JNI exports)"
done

say "Drop these into an app's src/main/jniLibs/<abi>/ to load with System.loadLibrary(\"agent_jni\")."
