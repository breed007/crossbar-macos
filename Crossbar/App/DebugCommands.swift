#if DEBUG
import AppKit
import SystemConfiguration

/// Debug-only command-line hooks for exercising the helper from Terminal. They run
/// inside the signed Crossbar binary, which is the only caller the helper accepts,
/// so `/Applications/Crossbar.app/Contents/MacOS/Crossbar <flag>` tests the real
/// path. Build with `scripts/dev-build.sh`.
///
///   --helper-status                    print the SMAppService status
///   --helper-register                  register the helper (then approve in System Settings)
///   --helper-unregister                remove it
///   --helper-toggle <serviceID> on|off toggle through the helper only
///   --toggle <serviceID> on|off        toggle through ToggleRouter (helper, else sudo)
///   --helper-selftest                  no-op re-assert of every service, then bad IDs
///   --services                         print the services as the popover would list them
///   --login-item [on|off]              print, or set, Launch at Login
enum DebugCommands {
    /// Returns an exit code if a debug flag was handled, or nil to launch normally.
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2, args[1].hasPrefix("--") else { return nil }
        let helper = HelperClient()

        switch args[1] {
        case "--helper-status":
            print("helper status: \(helper.status.label)")
            return 0

        case "--helper-register":
            return attempt("register", helper) { try helper.register() }

        case "--helper-unregister":
            return attempt("unregister", helper) { try helper.unregister() }

        case "--helper-toggle", "--toggle":
            guard args.count >= 4, ["on", "off"].contains(args[3]) else {
                print("usage: \(args[1]) <serviceID> on|off"); return 64
            }
            let id = args[2], on = args[3] == "on"
            let name = liveServices().first { $0.id == id }?.name ?? id
            if args[1] == "--helper-toggle" {
                return attempt("helper set \(id) \(args[3])", helper) {
                    try blocking { try await helper.setEnabled(on, serviceID: id) }
                }
            }
            return attempt("routed set \(id) \(args[3])", helper) {
                try blocking { try await ToggleRouter.shared.setEnabled(on, serviceID: id, serviceName: name) }
            }

        case "--helper-selftest":
            return selfTest(helper)

        case "--services":
            for s in liveServices() {
                print("\(s.enabled ? "on " : "off") \(s.name)  [\(s.id)]")
            }
            return 0

        case "--login-item":
            if args.count >= 3 {
                let on = args[2] == "on"
                guard attempt(on ? "enable launch at login" : "disable launch at login", helper,
                              { try LoginItem.setEnabled(on) }) == 0 else { return 1 }
            }
            print("launch at login: \(LoginItem.status.label)")
            return 0

        default:
            return nil   // not ours; launch normally
        }
    }

    /// Re-assert every service's current state through the helper (proves the root
    /// write without changing anything), then check that bad IDs are refused.
    private static func selfTest(_ helper: HelperClient) -> Int32 {
        var failures = 0
        let services = liveServices()
        guard !services.isEmpty else { print("FAIL: no services read"); return 1 }
        for s in services {
            if attempt("no-op set \(s.name) \(s.enabled ? "on" : "off")", helper, {
                try blocking { try await helper.setEnabled(s.enabled, serviceID: s.id) }
            }) != 0 { failures += 1 }
        }
        let changed = zip(services, liveServices()).filter { $0.enabled != $1.enabled }
        if !changed.isEmpty { print("FAIL: a no-op changed \(changed.map(\.0.name))"); failures += 1 }

        for (label, id) in [("unknown ID", "00000000-0000-0000-0000-000000000000"),
                            ("malformed ID", "x\nforged log line")] {
            do {
                try blocking { try await helper.setEnabled(false, serviceID: id) }
                print("FAIL: \(label) was accepted"); failures += 1
            } catch PrivilegedToggleError.helperReportedError(let code)
                        where code == HelperConstants.ErrorCode.unknownServiceID {
                print("ok: \(label) refused with \(code)")
            } catch {
                print("FAIL: \(label): \(error)"); failures += 1
            }
        }
        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }

    /// Every service in the current set, read straight from SCPreferences.
    private static func liveServices() -> [(id: String, name: String, enabled: Bool)] {
        guard let prefs = SCPreferencesCreate(nil, "Crossbar.debug" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return [] }
        return services.compactMap { s in
            guard let id = SCNetworkServiceGetServiceID(s) as String?,
                  let name = SCNetworkServiceGetName(s) as String? else { return nil }
            return (id, name, SCNetworkServiceGetEnabled(s))
        }
    }

    private static func attempt(_ label: String, _ helper: HelperClient, _ work: () throws -> Void) -> Int32 {
        do {
            try work()
            print("ok: \(label) (helper \(helper.status.label))")
            return 0
        } catch {
            print("FAIL: \(label): \(error) (helper \(helper.status.label))")
            return 1
        }
    }

    /// Run async work to completion from this synchronous, pre-AppKit context.
    private static func blocking(_ work: @escaping () async throws -> Void) throws {
        final class Box: @unchecked Sendable { var error: Error? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await work() } catch { box.error = error }
            done.signal()
        }
        done.wait()
        if let error = box.error { throw error }
    }
}
#endif
