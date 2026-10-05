# Changelog

All notable changes to crossbar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] — 2026-10-04

### Fixed
- **Set Up Passwordless Toggling no longer dead-ends on "Operation not permitted."**
  macOS refuses to register the helper while an earlier request is still waiting
  for approval, and 0.5.0 showed that as an error with no way forward. Any setup
  failure now points to Login Items & Extensions, where it can be fixed. Setup
  also counts a registration that's waiting for approval as success even if macOS
  reports an error, which Switchback ran into on macOS 27.
- If the helper is approved but can't be reached, crossbar falls back to the sudo
  rule instead of failing.
- After setting up the helper, the popover footer updates right away.
- A `networksetup` that hangs is stopped after 20 seconds instead of freezing the
  row.

### Added
- **A warning before you lose your connection.** Turning off the service carrying
  your traffic says where traffic will go, or that you'll go offline. It always asks
  when you'd go offline or an SSH or Screen Sharing session could drop. The handoff
  question can be turned off.
- **"Connecting…"** on a service you just turned on, until it gets an address.
- **Menu bar feedback:** "Wi-Fi off" next to the icon after a toggle, and an
  optional setting to keep the active network's name there.
- **Settings window:** Launch at Login, the menu bar name, the handoff question,
  and the helper's status with Set Up, Open Login Items, and Remove.
- **Keyboard control:** Up and Down choose a row, Space or Return toggles it,
  Escape closes.
- **Shortcuts and Focus:** Set Network Service and Get Network Service actions,
  Spotlight and Siri phrases, and a Focus filter that turns services on and off
  when a Focus starts. Each automated change posts a notification.
- The "active route" label fades in on its new row when traffic moves.

### Changed
- The helper logs each change to the unified log (service ID and result, never
  names), refuses malformed requests before logging them, and quits when idle.
- crossbar no longer runs `networksetup` to read services. It finds the interfaces
  System Settings hides through the I/O Registry, so refreshes are faster.
- Settings moved out of the popover footer into the Settings window.
- Built from `project.yml` with XcodeGen, with a unit-test suite.

## [0.5.0] — 2026-07-27

### Added
- **Passwordless toggling via a privileged helper (no more sudoers rule).**
  Crossbar can now install a signed background helper (`SMAppService`) that
  performs the enable/disable directly, over an authenticated XPC connection.
  Set it up from the popover footer → "Set up passwordless toggling…" and
  approve it under System Settings → Login Items & Extensions. This replaces the
  manual `/etc/sudoers.d/crossbar` step for anyone who opts in.
  - The helper pins its caller to Crossbar's own code signature (Team ID), and
    re-validates the target service **ID** against live config before writing —
    so a service name can never be spoofed into a privileged change, and
    duplicate service names are unambiguous.
  - The `networksetup`/sudoers path (Backend A) remains as an automatic fallback
    for anyone who doesn't install the helper, or on managed Macs.
- **Launch at Login** — a checkbox in the popover footer registers Crossbar to
  start automatically (`SMAppService`).

### Design

- Added [Backend B design doc](docs/backend-b-design.md) documenting the helper
  architecture, the XPC contract, and the signature-pinning security model.

## [0.4.0] — 2026-06-13

### Fixed
- **A failed toggle no longer leaves the switch stuck.** When a toggle failed
  (most commonly on first run before the sudoers rule is installed), the switch
  stayed greyed-out and showing the wrong position, and reopening the popover
  didn't recover it — the no-op refresh was deduplicated away, so no rebuild
  ever re-enabled the row. The row is now reverted and re-enabled directly on
  failure.
- **Long service names are now recoverable** — the hover tooltip includes the
  full service name, so names that truncate in the row can still be read.
- Hardened the `networksetup` name parser against a service whose name legiti-
  mately begins with `*` (the disabled-marker character).

### Changed
- **Location Services prompt is deferred to first popover open** instead of
  firing unprompted at launch, so the ask (for the Wi-Fi SSID) has visible
  context.

### Accessibility
- **Status is no longer conveyed by color alone.** The status dot now varies by
  shape too — filled circle (connected), hollow circle (enabled but down),
  slashed circle (disabled) — so it stays legible for color-blind users.
- Each service row now carries a VoiceOver label describing its full state
  (name, connectivity, active-route, SSID), and the toggle is labeled.

## [0.3.0] — 2026-06-12

### Changed
- **Signed and notarized with a Developer ID.** Builds are now Developer ID-signed
  with the Hardened Runtime and notarized by Apple, so downloaded copies open
  cleanly — the previous `xattr -dr com.apple.quarantine` step is no longer needed.
- Added a reproducible release pipeline (`scripts/release.sh` +
  `scripts/ExportOptions.plist`): archive → Developer ID export → notarize →
  staple → package as a universal `.zip` and a `.dmg`.

## [0.2.1] — 2026-06-10

### Changed
- **New app icon and menu bar glyph** — three network nodes strung along a
  diagonal crossbar (reads as both a network link and a barbell), replacing the
  globe-with-crossbar mark. The menu bar glyph now matches the app icon.

## [0.2.0] — 2026-06-02

### Fixed
- **Active-route marker now works on IPv6-only networks.** The primary-service
  lookup fell back only to IPv4; it now also consults the IPv6 global state, so
  the "active route" marker appears when IPv4 has no default route.
- **A just-clicked toggle is frozen immediately** while its privileged call is
  in flight, so a rapid second click can no longer leave the switch showing the
  wrong position until the next refresh.
- **Menu bar alert badge is now meaningful.** It previously lit whenever *any*
  service was disabled — permanently on for Macs that ship with an inactive
  service. It now signals only when no service is currently routing traffic.
- Guarded all `SCDynamicStore` reads against a failed store creation, removing a
  latent force-unwrap crash under resource exhaustion.

### Changed
- The service list and menu bar icon only update when the state actually
  changes (`removeDuplicates`), so an unrelated network blip no longer tears
  down popover rows mid-hover or needlessly redraws the icon.
- Overlapping background refreshes are coalesced — at most one
  `networksetup -listallnetworkservices` runs at a time.
- Internal: the toggle `Task` no longer captures `self` strongly.

## [0.1.0] — 2026-05-31

First release.

### Added
- Menu bar agent app (no Dock icon) listing the Mac's network services —
  the same set System Settings shows.
- Per-service **enable/disable toggle**, via a passwordless `sudo` +
  `networksetup` backend behind a `PrivilegedToggle` protocol seam (so the
  backend can change without touching the UI).
- **Event-driven, no-polling** read layer built on `SCDynamicStore`; live state
  updates as the network changes.
- **Status dot** per service: connected / enabled-but-down / disabled.
- **"Active route" marker** on the service actually carrying traffic; dormant
  services are dimmed so the live ones stand out.
- **Category ordering**: wired → Wi-Fi → VPN → bridges/aggregates → other.
- **Wi-Fi SSID** display (via Location Services, the only way macOS 14+ exposes it).
- **Hover details**: route state, IP address, router.
- Menu bar **icon badge** when a service is disabled.
- Popover footer: **Network Settings…** deep link and **Quit**.
- **Application icon** (globe + crossbar) for Finder and Get Info.
- **Universal** build (Apple Silicon + Intel).

[0.6.0]: https://github.com/breed007/crossbar-macos/releases/tag/v0.6.0
[0.5.0]: https://github.com/breed007/crossbar-macos/releases/tag/v0.5.0
[0.4.0]: https://github.com/breed007/crossbar-macos/releases/tag/v0.4.0
[0.3.0]: https://github.com/breed007/crossbar-macos/releases/tag/v0.3.0
[0.2.1]: https://github.com/breed007/crossbar-macos/releases/tag/v0.2.1
[0.2.0]: https://github.com/breed007/crossbar-macos/releases/tag/v0.2.0
[0.1.0]: https://github.com/breed007/crossbar-macos/releases/tag/v0.1.0
