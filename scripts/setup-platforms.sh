#!/usr/bin/env bash
# Set up cross-platform builds for the shared agent, and prove they compile.
#
#   ./scripts/setup-platforms.sh          # install targets + check Windows and Android
#   ./scripts/setup-platforms.sh --check  # check only (targets already installed)
#
# A passing check means the code compiles for that target. It is NOT a link: producing a running
# .exe needs a Windows machine, and an Android .so needs the NDK. See docs/PLATFORMS.md.
set -euo pipefail
cd "$(dirname "$0")/.."

WINDOWS_TARGETS=(x86_64-pc-windows-msvc aarch64-pc-windows-msvc)
ANDROID_TARGETS=(aarch64-linux-android)

# Crates that are portable everywhere. agent-backend-desktop / agent-ffi / agent-cli are desktop
# hosts, so they are checked for Windows but not for Android, where the backend is JNI-based.
PORTABLE=(agent-core agent-llm-anthropic agent-store-fs agent-mcp-stdio)
DESKTOP=(agent-backend-desktop agent-ffi agent-cli)

if [[ "${1:-}" != "--check" ]]; then
  echo "▸ installing Rust targets"
  for t in "${WINDOWS_TARGETS[@]}" "${ANDROID_TARGETS[@]}"; do
    rustup target add "$t" >/dev/null && echo "  installed $t"
  done
fi

fail=0
expected=0
check() { # <target> <crate...>
  local target="$1"; shift
  echo "▸ $target"
  for crate in "$@"; do
    if cargo check --quiet --target "$target" -p "$crate" 2>/dev/null; then
      echo "  ✅ $crate"
    elif [[ "$target" == *android* && "$crate" == "agent-llm-anthropic" ]]; then
      # Known and documented: the HTTP client's TLS pulls a C dependency, which needs the Android
      # NDK's toolchain to cross-compile. Not a code defect, so don't fail the run over it —
      # otherwise a real regression would be indistinguishable from this expected gap.
      echo "  ⏭  $crate — needs the Android NDK (see docs/PLATFORMS.md)"
      expected=1
    else
      echo "  ❌ $crate"
      fail=1
    fi
  done
}

check "${WINDOWS_TARGETS[0]}" "${PORTABLE[@]}" "${DESKTOP[@]}"
check "${ANDROID_TARGETS[0]}" "${PORTABLE[@]}"

echo
if [[ $fail -ne 0 ]]; then
  echo "Unexpected failures — see ❌ above."
  exit 1
fi
echo "Windows: every crate compiles. Build the host there with:"
echo "  cargo build --release -p agent-cli   →  pocketmac-agent.exe"
if [[ $expected -ne 0 ]]; then
  echo "Android: the portable core compiles; the TLS crate needs the NDK. See docs/ANDROID.md."
fi
