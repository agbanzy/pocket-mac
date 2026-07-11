# ADR 0002 — Raw Network.framework, not Multipeer Connectivity

Status: accepted · Date: 2026-07-11

## Decision
Use `NWListener` / `NWBrowser` / `NWConnection` directly for LAN discovery and transport.

## Why
Multipeer Connectivity is Apple-only, opaque, and mixes WiFi/AWDL/Bluetooth unpredictably. Raw
Network.framework gives a single `NWConnection` abstraction we reuse **verbatim** for the relay path
(WSS) with full control over framing and the security layer — one transport interface for both LAN
and internet. That reuse is what makes "keyed to identity, not path" true in code (`Transport`).

## Consequences
- iOS must ship `NSLocalNetworkUsageDescription` + `NSBonjourServices` (`_pocketmac._tcp`) or the
  browser silently returns nothing; denial surfaces as `kDNSServiceErr_PolicyDenied` (-65570).
- Connect to the `NWEndpoint` the browser returns — never hand-resolve `host.local` (unreliable since
  iOS 17). Encoded in `DiscoveredService.makeConnection()`.
- Unicast Bonjour over TCP needs **no** multicast entitlement (which would require Apple approval).
