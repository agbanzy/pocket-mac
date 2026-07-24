# Platforms

One shared Rust brain, one agent loop, three targets. Adding a platform means implementing
`ComputerBackend` and choosing a host — never rewriting the agent.

## Layout

| Crate | Role | Portable? |
|---|---|---|
| `agent-core` | the agent loop, tool registry, task model | yes — no OS, no HTTP |
| `agent-llm-anthropic` | Claude client, prompt caching | yes (TLS varies, see below) |
| `agent-mcp-stdio` | MCP servers over JSON-RPC/stdio | yes |
| `agent-store-fs` | durable task history | yes |
| `agent-backend-desktop` | capture + input for Windows/macOS/Linux | desktop |
| `agent-ffi` | C ABI for native hosts (Swift, C#, Kotlin/JNI) | yes |
| `agent-cli` | standalone `pocketmac-agent` binary | desktop |

## Hosts

- **macOS** — the menu-bar helper links `agent-ffi`'s static archive and calls `pm_agent_run`.
  Shipping today.
- **Windows / Linux** — use `agent-cli` directly; there is no GUI to write:
  `pocketmac-agent "open the browser and search for flights"`, `pocketmac-agent --history`.
  A tray app can wrap the same FFI later.
- **Android** — `agent-core` compiles for `aarch64-linux-android`. The remaining work is a JNI shim
  over `agent-ffi` plus an `AccessibilityService` (input) and `MediaProjection` (capture)
  implementation of `ComputerBackend`. See `docs/ANDROID.md`.

## Verified cross-compilation

From macOS, `cargo check --target x86_64-pc-windows-msvc` passes for **all seven crates**, including
the Win32 input path in `enigo` and the whole FFI + CLI stack. `agent-core` also checks against
`aarch64-linux-android`.

Two limits worth stating plainly:

- **`cargo check` is not a link.** It proves the code compiles for the target; producing a running
  `.exe` still needs a Windows machine (or a cross-linker). Nothing here has executed on Windows.
- **C dependencies need the target's toolchain.** This bit us: `rustls` pulls `ring`, which compiles
  C, and cross-compiling that from macOS fails on missing target headers (`assert.h`). The fix was
  also the better design — see below.

## TLS per platform

```toml
[target.'cfg(windows)'.dependencies]
reqwest = { ..., features = ["json", "native-tls"] }   # SChannel: OS trust store, no bundled C crypto

[target.'cfg(not(windows))'.dependencies]
reqwest = { ..., features = ["json", "rustls-tls"] }   # what the signed macOS helper already ships
```

Windows uses its own TLS stack, so nothing has to be compiled from C and certificates come from the
system store. macOS deliberately keeps `rustls`: that link is already signed, notarised, and shipping,
and there is no reason to churn it. Android will follow the Windows approach once the NDK is wired up.

## Building

```bash
cargo build --release -p agent-cli          # native host binary
cargo check --target x86_64-pc-windows-msvc # Windows compile check from any machine
```

On Windows, with the MSVC build tools installed: `cargo build --release` produces
`pocketmac-agent.exe`, which needs no extra runtime.
