# ADR 0004 — LaunchAgent (not LaunchDaemon), Developer-ID (not App Store)

Status: accepted · Date: 2026-07-11

## Decision
The Mac helper is a menu-bar `LSUIElement` app, auto-started as a **LaunchAgent** via `SMAppService`,
signed **Developer ID** and notarized for direct download.

## Why LaunchAgent, not LaunchDaemon
A root/pre-login **daemon** runs outside the Aqua GUI session and physically cannot post session
`CGEvent`s nor hold the user's Accessibility (TCC) grant. The helper must run **in the user session**,
so it is a LaunchAgent. `LoginItemManager` uses `SMAppService.mainApp`.

## Why not the Mac App Store
The App Sandbox forbids being an Accessibility client and posting global `CGEvent`s to other
processes — exactly what this helper does. It therefore cannot pass App Store sandbox review (same
reason as Karabiner-Elements / BetterTouchTool). Distribution is Developer-ID direct download with a
self-hosted updater (Sparkle, later). Entitlements: Hardened Runtime **on**, App Sandbox **off**.

## Current status / gap
No **Developer ID Application** certificate exists yet (only Apple Development + Apple Distribution).
Milestone 0 runs the helper **Development-signed** locally — which also gives the stable signature
the Accessibility grant needs across rebuilds. Notarized external distribution is deferred until a
Developer-ID cert is created on the INNOEDGE account.
