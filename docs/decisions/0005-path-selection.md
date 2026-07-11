# ADR 0005 — Seamless LAN↔relay path selection

Status: accepted · Date: 2026-07-11

## Context
The product promise is "control your Mac from anywhere" with an identical experience on WiFi and over
the internet. The `SecureSession` is already keyed to device identity, not network path, so both
transports carry it unchanged — the remaining question is *policy*: which path, and when to switch.

## Decision
An iOS `PathCoordinator` keeps a session to the paired Mac up over the **best available path**:
- **Prefer LAN.** If the paired Mac is discovered on the LAN (Bonjour name match, with the handshake
  authenticating identity regardless), connect over `NWConnectionTransport` — lowest latency.
- **Fall back to relay.** Otherwise, if a relay URL is configured, connect over `RelayTransport`
  using the pairing-time rendezvous token.
- **Re-select on change.** Re-evaluate when the discovered-service list changes (LAN appears/vanishes)
  and when `NWPathMonitor` reports a network change (WiFi↔cellular, connectivity up/down). A switch is
  just a re-handshake; if already secured on the preferred path, leave it (no churn).

The chip shows the live path (`Encrypted · LAN` / `Encrypted · Remote`). The relay URL is read from
`UserDefaults` (`com.innoedge.pocketmac.relayURL`) so it can be set once the relay is deployed.

## Consequences
- Auto-connect: pairing (or launching while paired) brings the session up with no manual "Connect".
- Handshake authenticates identity, so a Bonjour name collision cannot connect the wrong Mac.
- The **live WiFi↔cellular handoff is only fully exercisable on a physical device**; the Simulator
  validates auto-connect + LAN preference. Verified: builds + launches with the coordinator + path
  monitor active, no crash.

## Not yet
Debounced switching under flapping networks, and a "keep on relay even when LAN briefly returns"
hysteresis, are refinements deferred until real-device testing shows they're needed. APNs push-to-wake
(Phase 11) will let the phone signal a sleeping-socket Mac to re-dial the relay instead of the Mac
polling a parked rendezvous.
