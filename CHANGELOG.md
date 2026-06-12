# Changelog

All notable changes to crossbar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.1]: https://github.com/breed007/crossbar-macos/releases/tag/v0.2.1
[0.2.0]: https://github.com/breed007/crossbar-macos/releases/tag/v0.2.0
[0.1.0]: https://github.com/breed007/crossbar-macos/releases/tag/v0.1.0
