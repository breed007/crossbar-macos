# Design notes

This document records the *why* behind crossbar's scope — what it does, what it
deliberately doesn't, and the reasoning — so the decisions survive past the
moment they were made. If you're considering a feature, start here.

## The one-sentence test

Every feature must pass this:

> **Does this help me flip a network interface (NIC) on or off, or see at a
> glance which NICs exist and what state they're in?**

If a proposed feature doesn't pass, it's out of scope — no matter how adjacent or
convenient it seems. crossbar is a sharp, single-purpose tool; that focus is the
feature.

## The architecture that scope rests on

crossbar is built around one fact: **reading network state is unprivileged;
changing it requires root.** That split drives everything:

- **Read layer** — `StatusMonitor` over `SCDynamicStore` (SystemConfiguration),
  fully event-driven, no polling.
- **Write layer** — a `PrivilegedToggle` protocol whose v1 backend shells out to
  `networksetup` via a narrowly-scoped passwordless `sudo` rule.

A feature that can't be expressed through *both* of those mechanisms — read it
from SystemConfiguration, change it through `networksetup` — is a sign it doesn't
belong in this app, because it would require bolting on a parallel framework and
a second privileged path.

## Non-goals (and why)

These are intentionally **not** built, and not open to "just add it" requests.
If you think one is genuinely needed, open an issue and make the case against
the one-sentence test first.

### Bluetooth enable/disable — won't do

The most common suggestion, and a deliberate no. Reasoning:

- **It's not a NIC.** Bluetooth is a separate radio/peripheral subsystem, not a
  network service. It doesn't appear in `SCNetworkServiceCopyAll`, has no entry
  in System Settings → Network, isn't part of the service order, and never owns a
  default route. It sits outside the exact mental model crossbar is built around
  ("these are my network interfaces and which one is carrying traffic").
- **The architecture doesn't extend to it.** Bluetooth power state isn't in
  `SCDynamicStore` (you'd need `IOBluetooth`/`CoreBluetooth` and a different
  notification mechanism — a whole parallel monitor), and `networksetup` has no
  Bluetooth verb. Toggling it means either a third-party dependency (`blueutil`,
  and the app is intentionally dependency-free) or private `IOBluetooth` SPI
  (unsupported, breaks across macOS versions, and muddies the clean sudoers
  story). Adding it roughly doubles the surface area for something that isn't a
  NIC.
- **The native affordance is already good.** Unlike flipping a network service
  (buried four clicks deep in System Settings — the whole reason crossbar
  exists), macOS already gives Bluetooth a first-class one-click toggle in
  Control Center and an optional dedicated menu bar icon. The "this is buried,
  surface it" justification simply doesn't apply.
- **The genuinely-network slice is already covered.** Bluetooth PAN (the one case
  where Bluetooth carries IP) *is* a real `SCNetworkService`, so if you have a
  BT-PAN service configured it already appears in crossbar for free.

If a compelling need ever emerges, the principled approach — one that respects the
architecture — would be a clearly separated "Radios" section in the popover with
its own monitor and toggle path, explicitly **not** mixed into the network-service
list. Even then, gate it behind a real user need, not "because we can."

### Other non-goals

- **Network service priority reordering** — that's configuration surgery, not a
  glance-and-flip action; the OS owns it.
- **Network locations switching** — a different mental model (whole-config
  profiles), not per-service state.
- **Proxy configuration** — debug-level detail, not glance data.
- **VPN configuration / connect-disconnect / Apple Network Relay** — connection
  management is a different job than enabling the *service*. (A VPN that is a
  configured network service still shows up and can be made active/inactive like
  any other.)
- **Traffic/bandwidth graphs, speed tests, public-IP lookups** — monitoring and
  diagnostics, not interface state. Different app.

The throughline: adding adjacent-but-different capabilities (Bluetooth today,
AirDrop / Hotspot / VPN-connect / bandwidth graphs tomorrow) is exactly how a
focused utility drifts into a bloated "network manager." crossbar says no on
purpose.

## When the full detail is actually wanted

crossbar deliberately shows only glance data (state, IP, route, router, SSID).
For everything it omits — subnet, DNS, search domains, IPv6, proxies, and the
non-goals above — the per-service **Network Settings…** link opens Apple's native
pane. That's the escape hatch that lets crossbar stay small.
