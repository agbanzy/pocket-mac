# Android target — design

Android is the one platform that cannot reuse the desktop backend: there is no global mouse, and
both capture and input are permissioned services rather than library calls. The Rust `agent-core`
loop is unchanged — only a new `ComputerBackend` and a thin JNI bridge are required.

## Why not `agent-backend-desktop`

`enigo`/`xcap` target desktop window systems (Win32 / CoreGraphics / X11-Wayland). On Android:

| Need | Desktop | Android |
|---|---|---|
| Capture | `xcap` grabs a monitor | `MediaProjection` + `ImageReader` (user must approve a capture consent dialog per session) |
| Input | `enigo` synthesizes OS events | `AccessibilityService.dispatchGesture()` (taps/swipes) + `performGlobalAction()` (back/home/recents); text via `ACTION_SET_TEXT` on the focused node |
| Coordinates | one desktop, DPI-scaled | device pixels; rotation changes the space mid-session |
| Permission | TCC / UAC | `BIND_ACCESSIBILITY_SERVICE` (user enables in Settings) + per-session projection consent |

## Shape

```
android/
  app/                                  Kotlin app (controller UI + the target service)
    PocketMacAccessibilityService.kt    dispatchGesture / performGlobalAction / setText
    ScreenCaptureService.kt             MediaProjection → ImageReader → JPEG bytes
    AgentBridge.kt                      external fun runTask(...) — JNI into the Rust core
  rust/
    agent-backend-android/              ComputerBackend impl, calls back into Kotlin over JNI
```

`agent-backend-android` implements `ComputerBackend` by trampolining to Kotlin through JNI
(`jni` crate): `capture()` calls `ScreenCaptureService.grabJpeg()`, `execute(action)` maps each
`Action` to a gesture/global-action/text call. The mapping:

| `Action` | Android |
|---|---|
| `LeftClick` | `dispatchGesture` — 50 ms tap at (x, y) |
| `DoubleClick` / `TripleClick` | repeated taps inside the double-tap timeout |
| `RightClick` | long-press (`dispatchGesture`, ~600 ms) — the platform's context gesture |
| `LeftClickDrag` | `dispatchGesture` path from start → end |
| `Scroll` | swipe stroke opposite the scroll direction, or `ACTION_SCROLL_FORWARD/BACKWARD` on the node under the point |
| `Type` | `ACTION_SET_TEXT` on the focused node (falls back to per-char `KeyEvent` via IME) |
| `Key` back/home/recents | `performGlobalAction(GLOBAL_ACTION_BACK/HOME/RECENTS)` |
| `MouseMove` / `CursorPosition` | no-ops — Android has no persistent cursor; report "not applicable" |

## Two roles, one app

The Android app plays **both** roles, selectable at runtime:

1. **Controller** — the phone drives *another* machine (like the iOS app). Needs a Kotlin port of the
   wire protocol; see the conformance-vector requirement below.
2. **Target** — the phone *is* the machine being driven (Accessibility + MediaProjection above).

## Prerequisite: protocol conformance vectors

`shared/PocketMacKit` (Swift) is the de-facto protocol spec and the `browser/` TypeScript port has
already drifted (its `ControlOpcode` stops at `StopVideo = 6`). Before a Kotlin port is written, the
frame codec + Noise handshake need a language-neutral spec plus **test vectors** every port must
reproduce byte-for-byte, so drift is caught by tests rather than by a failed pairing on a user's
phone.

## Build prerequisites (not present on this Mac)

- Android SDK + NDK, `cargo-ndk`, Rust targets `aarch64-linux-android`, `armv7-linux-androideabi`
- The Rust core cross-compiles to a `.so` per ABI, bundled in the APK and loaded via `System.loadLibrary`

Nothing here changes `agent-core`; Android is an additional `ComputerBackend` plus the JNI bridge.
