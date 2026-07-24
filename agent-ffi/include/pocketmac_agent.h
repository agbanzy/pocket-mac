// Pocket Mac agent — C ABI.
//
// One shared Rust brain (agent loop + Claude client + desktop backend + task store) callable from
// any native host: the Swift menu-bar helper, a Windows service, or an Android JNI shim.
//
// Link against libpocketmac_agent.a (static) or .dylib/.so/.dll (dynamic).

#ifndef POCKETMAC_AGENT_H
#define POCKETMAC_AGENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Progress callback. `kind` is one of: "started", "thinking", "action", "done", "error".
// Both strings are only valid for the duration of the call — copy what you need.
// Invoked from a worker thread; hop to your UI queue before touching UI.
typedef void (*pm_event_cb)(const char *kind, const char *text, void *ctx);

// Run one task to completion. Blocks the calling thread — call it off your UI thread.
//
//   prompt     natural-language task (required)
//   api_key    Anthropic API key (required)
//   store_dir  directory for durable task history; NULL for a temp dir
//   persona    system-prompt prefix, e.g. a JARVIS persona; NULL for none
//   cb, ctx    progress callback and an opaque pointer handed back to it
//
// Returns 0 on success; non-zero on failure (see pm_agent_last_error):
//   1 task failed/cancelled, 2 bad arguments, 3 backend init, 4 task store, 5 runtime.
int32_t pm_agent_run(const char *prompt,
                     const char *api_key,
                     const char *store_dir,
                     const char *persona,
                     pm_event_cb cb,
                     void *ctx);

// Ask the in-flight task to stop at the next step boundary.
void pm_agent_cancel(void);

// Last error message, or NULL. Borrowed — valid until the next failing call.
const char *pm_agent_last_error(void);

#ifdef __cplusplus
}
#endif

#endif // POCKETMAC_AGENT_H

// ── Linking (macOS) ──────────────────────────────────────────────────────────
// clang -I include your_host.c libpocketmac_agent.a \
//   -framework CoreGraphics -framework CoreFoundation -framework AppKit \
//   -framework CoreMedia -framework CoreVideo -framework Carbon \
//   -framework ScreenCaptureKit -framework AVFoundation -framework IOKit
//
// Swift: add the .a to the target, set the bridging header to this file, link the same
// frameworks, and call pm_agent_run off the main queue (it blocks).
//
// ── MCP tools ────────────────────────────────────────────────────────────────
// Drop an mcp.json beside the task-store directory (on macOS:
// ~/Library/Application Support/PocketMac/mcp.json) to give the agent tools beyond the screen:
//
//   { "servers": [ { "id": "fs", "command": "npx",
//                    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path"] } ] }
//
// Each server's tools are registered as "<id>__<tool>" alongside the built-in computer tool. A
// server that fails to start is skipped, never fatal to the task.
