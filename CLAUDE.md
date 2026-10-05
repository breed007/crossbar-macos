# Crossbar — notes for Claude

Menu bar agent (AppKit, macOS 14+) that turns network services on and off.
Public repo `breed007/crossbar-macos`, MIT. Distributed through GitHub releases and
the `breed007/tap` Homebrew cask. Not sandboxed, not on the Mac App Store.

Read `DESIGN.md` before adding features (the one-sentence scope test and the
non-goals), and `docs/backend-b-design.md` before touching the helper.

## Build

- The Xcode project is generated: edit `project.yml`, then `xcodegen generate`.
  `Crossbar.xcodeproj/` is ignored.
- `scripts/test.sh` runs the unit tests (ad-hoc signed, no privileges).
- `scripts/dev-build.sh` installs a Developer ID-signed Debug build to
  `/Applications`. Only a team-signed `com.breed.Crossbar` can talk to the helper,
  so helper work has to be tested this way.
- `scripts/release.sh` archives, notarizes, staples, and packages the `.zip` and
  `.dmg` into `dist/`.

## Architecture

- **Read layer:** `StatusMonitor` (SCDynamicStore notifications, no polling) builds
  `[NetworkServiceState]`. Unprivileged.
- **Write layer:** everything goes through `ToggleRouter.shared`
  (`PrivilegedToggle`). It uses the helper (Backend B, `HelperClient`) when
  approved, else `NetworksetupToggle` (Backend A, `sudo -n networksetup`, needs
  the sudoers rule). It falls back to A only when the helper can't be reached,
  never when the helper reported a failure. Neither backend ever prompts.
- **Helper:** `Helper/main.swift`, a root LaunchDaemon registered with
  `SMAppService.daemon`. One operation, `setEnabled` by service ID. Pins its
  caller with `HelperConstants.clientRequirement`, refuses malformed IDs before
  logging, re-validates IDs against live config, logs to the unified log
  (`subsystem == "com.breed.Crossbar.helper"`), exits after 60 idle seconds.
  `Shared/HelperConstants.swift` is compiled into both ends.

## Gotchas

- `SMAppService.register()` for the daemon can throw "Operation not permitted".
  On a first registration the status is already `.requiresApproval`, which is
  success. If a previous request is still pending, it stays unregistered until
  the user turns Crossbar on in Login Items & Extensions. See `HelperClient` and
  `HelperSetup`.
- `StatusMonitor.$services` is consumed with `removeDuplicates()`. Anything that
  changes without changing the service list (helper status, settings) has to
  rebuild the UI directly; `refreshNow()` won't.
- Debug flags (`App/DebugCommands.swift`, Debug builds only):
  `/Applications/Crossbar.app/Contents/MacOS/Crossbar --helper-selftest`,
  `--helper-status`, `--toggle <serviceID> on|off`, `--services`, and more.
- The keychain lists each Developer ID identity twice, so `codesign -s "Developer ID
  Application"` is ambiguous outside Xcode. Sign by SHA-1 hash, and check the
  result with `codesign -dvvv`; a failed re-sign leaves the old signature in place.
- The App Intents file is excluded from the test bundle, or the test process
  registers App Shortcuts with the system (learned in Switchback).

## Conventions

US English. Commit messages use `feat:`/`fix:`/`build:`/`docs:` prefixes and say
why. Never add a co-author or "generated with" line. Shipped prose (README,
release notes) gets an AI-writing-tells pass before release.
