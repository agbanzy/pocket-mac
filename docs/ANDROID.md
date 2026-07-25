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

## Prerequisite: protocol conformance vectors — done

This was a blocker and is now cleared. `shared/conformance/vectors.json` is the language-neutral
contract, and Swift and TypeScript both assert against it in their own test suites (`docs/PROTOCOL.md`).
Writing the Kotlin controller means implementing those tables and adding the same conformance test —
drift then fails CI instead of a user's pairing screen.

The drift that motivated it was real: the TypeScript port's `ControlOpcode` had stopped at
`StopVideo = 6`, so the browser client could not run an AI task at all and *threw* on a `taskEvent`
frame. The vectors caught it; it is fixed.

## What exists now

| Piece | State |
|---|---|
| `agent-core` compiles for `aarch64-linux-android` | ✅ verified |
| `agent-jni` — JNI exports, JVM callbacks, action marshalling | ✅ written, compiles and tested |
| Building the `.so` for Android | ⛔ needs the NDK |
| Kotlin `AgentHost` implementation | ⛔ not written |

`agent-jni` implements `ComputerBackend` *upwards*: it holds a `JavaVM` and a global ref (not the
borrowed `JNIEnv`, which is only valid on the thread that produced it) and attaches the current
thread per call, because the loop runs on tokio workers. Actions cross as the same JSON the desktop
backend uses, so adding one needs no JNI signature change.

```kotlin
object PocketMacAgent {
    init { System.loadLibrary("pocketmac_agent_jni") }
    external fun runTask(prompt: String, apiKey: String, storeDir: String,
                         persona: String?, host: AgentHost): Int
    external fun cancel()
}

/** Rust calls these on a worker thread — never Android's main thread. */
interface AgentHost {
    fun capture(): ByteArray        // JPEG of the screen, already downscaled
    fun screenWidth(): Int          // the coordinate space those bytes are in
    fun screenHeight(): Int
    fun execute(actionJson: String)
    fun onEvent(kind: String, text: String)  // started | thinking | action | done | error
}
```

`runTask` blocks — call it from `Dispatchers.IO`.

**Report `screenWidth`/`screenHeight` as the size of the image you return from `capture()`, not the
raw display size.** The model answers in that space and the loop passes the numbers straight back; if
the two disagree, every tap lands in the wrong place.

## Building the native library

```bash
export ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/<version>
cargo install cargo-ndk
rustup target add aarch64-linux-android armv7-linux-androideabi

cargo ndk -t arm64-v8a -t armeabi-v7a \
  -o android/app/src/main/jniLibs build --release -p agent-jni
```

**The remaining blocker is the NDK, not the code.** The HTTP client's TLS pulls a C dependency that
cannot cross-compile without the NDK's toolchain, which is why `cargo check --target
aarch64-linux-android` passes for the pure-Rust crates and fails at that one. Nothing here has run on
a device.

Nothing above changes `agent-core`; Android is a `ComputerBackend` implemented in Kotlin plus this
JNI bridge.
