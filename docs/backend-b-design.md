# Design: Backend B — SMAppService privileged helper

**Status:** Proposed · **Author:** breed · **Target:** macOS 14+
**Supersedes:** the `sudoers` NOPASSWD rule (Backend A) as the primary toggle path.

## One-line

Replace the manual `/etc/sudoers.d/crossbar` rule with an approved, signed
privileged helper daemon (`SMAppService`) that Crossbar talks to over XPC and
that writes network-service state directly via `SCPreferences` — removing the
one first-run step nobody outside the author will do.

## Problem

Backend A works but is gated on a scary manual step: the user must
`sudo visudo -f /etc/sudoers.d/crossbar` and paste a `NOPASSWD` rule before a
single toggle functions. For a personal tool that's fine; for a notarized,
Homebrew-installable app on other people's machines it's the single biggest
adoption blocker. The `PrivilegedToggle` protocol was built as a seam
specifically so this could be swapped without touching the UI. This is that swap.

## Goals

- **No manual privileged setup.** First run = a normal "approve in Login Items &
  Extensions" prompt, not a terminal ritual.
- **Do it right (three concrete controls, not a checklist):**
  1. the daemon verifies the *caller's* code signature (Team ID + bundle id),
  2. the daemon re-validates the target service **ID** against live config
     before writing (never trusts the client),
  3. the daemon is minimal — one operation, nothing else.
- **Fix two latent Backend-A bugs for free** by keying on the stable service
  **ID** instead of the display name: duplicate service names become
  unambiguous, and there's no `networksetup` subprocess to wedge.

## Non-goals

- No new user-facing features. Same job: enable/disable a network service.
- Not widening scope (Bluetooth/VPN-connect/locations stay out — see
  [DESIGN.md](../DESIGN.md)).
- Not removing Backend A from the codebase yet — it becomes the fallback (below).

## Architecture

```
 Crossbar.app (user, unprivileged)
   PopoverViewController
        │  setEnabled(id, name, on)
        ▼
   PrivilegedToggle  ◄─ protocol (UI knows only this)
        │
   SMAppServiceToggle (Backend B)         XPC mach service:
        │   xpc_connection to helper       com.breed.Crossbar.helper
 ═══════│════════ PRIVILEGE BOUNDARY ═══════════════════════════════
        ▼
   com.breed.Crossbar.helper  (root LaunchDaemon, from app bundle)
        1. verify caller signature  (xpc_connection_set_peer_code_signing_requirement)
        2. validate service ID exists in current SCNetworkSet
        3. SCNetworkServiceSetEnabled + SCPreferencesCommitChanges/ApplyChanges
```

The helper ships **inside** the app bundle
(`Contents/Library/LaunchDaemons/com.breed.Crossbar.helper.plist` +
`Contents/MacOS/CrossbarHelper`), is registered via
`SMAppService.daemon(plistName:)`, and runs as root under launchd.

## The XPC contract

One request, one reply. Deliberately tiny.

**Request** (client → helper):
| key | type | meaning |
|-----|------|---------|
| `op` | string | `"setEnabled"` (only value in v1) |
| `serviceID` | string | SCNetworkService **ID** — the authoritative target |
| `enabled` | bool | desired state |

**Reply** (helper → client):
| key | type | meaning |
|-----|------|---------|
| `ok` | bool | did the write commit + apply |
| `error` | string (optional) | reason on failure (unknown-id, commit-failed, …) |

The display **name** is intentionally *not* in the request — the helper derives
it from the validated ID if it needs it, so a client-supplied name can never
influence a privileged write.

## Security model (mutual authentication)

**Helper verifies the client** — the load-bearing control, and the one already
proven in the spike:

```swift
xpc_connection_set_peer_code_signing_requirement(peer,
  "identifier \"com.breed.Crossbar\" and anchor apple generic and " +
  "certificate leaf[subject.OU] = \"YA83Q8FTH3\"")
```

Enforced by the OS *per message*, before app code runs. Verified matrix from the
spike (macOS 26.5.2):

| caller signature | result |
|---|---|
| Developer ID, Team `YA83Q8FTH3` | **accepted** |
| ad-hoc (no team) | **rejected** (Peer Forbidden) |
| foreign signer (different OU) | **rejected** (Peer Forbidden) |

**Client verifies the helper** — the daemon is installed from Crossbar's own
signed bundle via `SMAppService`, so its provenance is inherent; as defense in
depth the client also pins the connection to the same team/identifier.

**Attack surface:** one endpoint, one op, root. The only client-controlled input
that reaches a privileged action is `serviceID`, and it's checked against the
live `SCNetworkSet` before use. No paths, no shell, no name strings, no
arbitrary writes.

## Privileged write mechanics

Running as root, no `AuthorizationRef` juggling is needed:

```swift
let prefs = SCPreferencesCreate(nil, "com.breed.Crossbar.helper" as CFString, nil)
guard let set = SCNetworkSetCopyCurrent(prefs),
      let svc = (SCNetworkSetCopyServices(set) as? [SCNetworkService])?
                  .first(where: { SCNetworkServiceGetServiceID($0) as String? == serviceID })
else { return .unknownService }              // (2) validate ID against live config
SCNetworkServiceSetEnabled(svc, enabled)
SCPreferencesCommitChanges(prefs)            // persist
SCPreferencesApplyChanges(prefs)             // make live
```

This is the same `SCPreferences` layer the read side already understands, so
the whole app now speaks one framework instead of shelling out.

## Interface change

`PrivilegedToggle` grows the stable ID (name retained only for messaging):

```swift
func setEnabled(_ enabled: Bool, serviceID: String, serviceName: String) async throws
```

Two call sites change: `PopoverViewController.handleToggle` (already holds
`NetworkServiceState.id`) and the two backends. Backend A keeps using `name`
(that's all `networksetup` accepts); Backend B uses `id`. Small, contained.

## Backend selection, migration & rollback

- **Primary:** Backend B. On first launch, if the helper isn't registered,
  Crossbar offers to install it → `SMAppService.register()` → the user approves
  in **Login Items & Extensions**. Status is observable via
  `SMAppService.status` (`.enabled` / `.requiresApproval` / `.notRegistered`).
- **Fallback:** if the helper is `.requiresApproval` and the user declines, or on
  a managed Mac where the daemon can't be approved, fall back to Backend A with
  the existing sudoers instructions (now framed as "advanced/manual"). The seam
  makes this a runtime choice, not a compile-time one.
- **Rollback / uninstall:** `SMAppService.unregister()` removes the daemon;
  document manual removal (`sudo` unload + delete) for the Homebrew-uninstall
  path. Removing the app should unregister on next launch.

## Build/release impact

`scripts/release.sh` must sign the embedded helper (same Developer ID/Team) and
notarize it as part of the app bundle. Hardened Runtime on both. The helper
needs no special entitlements — verifying a peer and writing `SCPreferences` as
root require none.

## Validation (spike results)

Every *load-bearing functional* mechanic of Backend B has been proven in
throwaway spikes. What remains unproven is framework *ceremony* (interactive
install/approval), not "does the core work."

**Spike 1 — client authentication** (the security control), macOS 26.5.2:

| caller signature | result |
|---|---|
| Developer ID, Team `YA83Q8FTH3` (Crossbar) | **accepted** |
| ad-hoc (no team) | **rejected** — Peer Forbidden |
| genuinely foreign signer (different OU) | **rejected** — Peer Forbidden |

`xpc_connection_set_peer_code_signing_requirement` is directly Swift-callable
(no C shim, no manual audit-token/`SecCode` parsing) and the requirement string
discriminates correctly, enforced by the OS per-message.

**Spike 2 — the privileged write**, macOS 26.5.2:

| mechanic | result |
|---|---|
| `SCPreferences` read fidelity vs `networksetup` (4 services) | ✅ all match |
| write-side symbols (`SetEnabled`/`CommitChanges`/`ApplyChanges`) resolve | ✅ |
| privilege boundary is real | ✅ `CommitChanges` **fails without root** |
| full write pipeline as **root** (no-op self-test: re-assert current state → commit → apply → re-read) | ✅ `before=true requested=true after=true persisted` for all 4 services; **nothing changed** |
| `SMAppService.daemon(plistName:)` API surface | ✅ constructible; `register`/`unregister`/`status` present; `status=notFound` (nothing installed yet) |

Net: client-auth and the root write are proven; the ID-validation guard is
exercised in the write spike (`unknown-service-id` path). The only remaining
unknown is the SMAppService *register + System Settings approval* flow, which
requires a real signed/notarized bundle and a human click — deferred to the
build, low-risk (Apple's intended replacement for `SMJobBless`), but honestly
**not yet verified**.

## Risks & open questions

- **Re-confirm on macOS 14.x before shipping.** Both spikes ran only on 26.5.2.
  The APIs are 13+/14+, so coverage is expected — but only one OS version was
  actually tested.
- **SMAppService register + approval flow is unverified** (see Validation). It's
  the well-trodden modern path, but proving it needs the real helper target
  installed once. First build milestone.
- **[decided] Backend A stays as the fallback** for declined-approval / managed
  Macs. Accepted cost: two toggle paths to maintain. The seam already makes this
  a runtime selection, so the maintenance surface is just the two conformances.
- **Approval UX.** `.requiresApproval` sends the user to System Settings; we need
  a clear in-popover state explaining the one-time approval, or it reads as
  broken. This is the main *product* work of Backend B.
- **Helper/app version skew.** SMAppService updates the daemon when the app
  updates; confirm behavior when a stale daemon is running against a new client
  (the signature pin is team/identifier, not version, so it won't hard-fail —
  but verify the op contract stays compatible).

## Rough plan

- [x] **Spike 1** — client signature pinning over XPC (security control). Done.
- [x] **Spike 2** — `SCPreferences` read fidelity + privileged write pipeline
      (commit/apply) proven as root; ID-validation guard exercised. Done.
1. **Helper target + real install** — build `CrossbarHelper` (embedded
   `LaunchDaemon`), register via `SMAppService.daemon`, and prove the
   register + System Settings approval flow end to end (the last unverified
   ceremony). Then a real single-service flip by ID over XPC.
2. `SMAppServiceToggle` conforming to `PrivilegedToggle`; wire the ID through
   `handleToggle`.
3. Backend selection (B primary, A fallback) + the approval UI state.
4. Update `release.sh` to sign/notarize the embedded helper; re-confirm on macOS 14.
5. Docs: README setup rewrite (approve-a-helper replaces visudo); CHANGELOG.
