# Changelog

All notable changes to Crossbar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/breed007/crossbar-macos/releases/tag/v0.1.0
