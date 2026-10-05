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
///   --services                         print the services as the popover lists them
///   --predict <serviceID>              what turning a service off would do (F3)
///   --remote-sessions                  remote sessions that could be cut off
///   --login-item [on|off]              print, or set, Launch at Login
///   --snapshot <dir>                   render the popover (live and sample) and Settings to PNGs
///   --ui-selftest                      drive the popover with key events and check the menu bar flash
///   --demo <view> [light|dark]         show popover, warning, or settings with sample data, until killed
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
            for s in StatusMonitor.readServices() {
                let order = s.orderIndex == Int.max ? "-" : String(s.orderIndex)
                print("\(s.isEnabled ? "on " : "off") \(s.isPrimary ? "*" : " ") \(s.name)  order=\(order)  "
                      + "ip=\(s.ipv4Address ?? "-") router=\(s.router ?? "-")  [\(s.id)]")
            }
            return 0

        case "--predict":
            guard args.count >= 3 else { print("usage: --predict <serviceID>"); return 64 }
            let prediction = RoutePrediction.disabling(args[2], in: StatusMonitor.readServices())
            print("\(prediction): \(prediction.sentence ?? "no warning")")
            return 0

        case "--remote-sessions":
            let sessions = RemoteSessions.current()
            print(RemoteSessions.warning(for: sessions) ?? "no remote sessions")
            return 0

        case "--demo":
            DemoData.active = true   // before anything reads services or settings
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            if args.count >= 4 { app.appearance = NSAppearance(named: args[3] == "light" ? .aqua : .darkAqua) }
            let controller = StatusItemController()
            let view = args.count >= 3 ? args[2] : "popover"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { controller.debugDemo(view) }
            app.run()   // until killed
            return 0

        case "--ui-selftest":
            return UISelfTest.run()

        case "--snapshot":
            guard args.count >= 3 else { print("usage: --snapshot <dir>"); return 64 }
            return Snapshots.write(to: URL(fileURLWithPath: args[2]))

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

/// Drives the real popover controller with synthetic key events, through a toggle
/// that records calls and changes nothing, then checks the menu bar flash.
private enum UISelfTest {
    private final class RecordingToggle: PrivilegedToggle {
        var calls: [(Bool, String)] = []
        func setEnabled(_ enabled: Bool, serviceID: String, serviceName: String) async throws {
            calls.append((enabled, serviceID))
        }
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print("\(ok ? "ok" : "FAIL"): \(label)"); if !ok { failures += 1 }
        }
        func key(_ code: UInt16, _ chars: String = "") -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)!
        }
        func pump(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        let monitor = StatusMonitor()
        let services = monitor.services
        // A dormant service, so Space won't need the F3 confirmation (which is modal).
        guard let dormantIndex = services.firstIndex(where: { !$0.isPrimary && $0.isEnabled }) else {
            print("FAIL: no enabled dormant service to drive"); return 1
        }
        let toggle = RecordingToggle()
        let controller = PopoverViewController(monitor: monitor, toggle: toggle)
        var closed = false
        controller.onClose = { closed = true }
        let view = controller.view as! KeyHandlingView
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        controller.prepareToShow()

        func highlighted() -> String? {
            var rows: [ServiceRowView] = []
            func walk(_ v: NSView) { if let r = v as? ServiceRowView { rows.append(r) }; v.subviews.forEach(walk) }
            walk(view)
            return rows.first(where: \.isHighlighted)?.serviceID
        }

        check(highlighted() == nil, "no highlight when the popover opens")
        view.keyDown(with: key(125))
        check(highlighted() == services.first?.id, "Down highlights the first row")
        view.keyDown(with: key(126))
        check(highlighted() == services.first?.id, "Up at the top stays on the first row")
        for _ in 0..<dormantIndex { view.keyDown(with: key(125)) }
        check(highlighted() == services[dormantIndex].id, "Down moves to row \(dormantIndex + 1)")
        view.keyDown(with: key(49, " "))
        pump()
        check(toggle.calls.count == 1 && toggle.calls.first?.0 == false
              && toggle.calls.first?.1 == services[dormantIndex].id,
              "Space turns off the highlighted service (\(services[dormantIndex].name))")
        check(highlighted() == services[dormantIndex].id, "the highlight stays on the toggled row")
        view.keyDown(with: key(53))
        check(closed, "Escape closes the popover")

        // Menu bar flash and the persistent name.
        let preferences = Preferences()
        let savedShowName = preferences.showNetworkName
        let item = StatusItemController()
        NotificationCenter.default.post(name: .crossbarServiceToggled, object: nil,
                                        userInfo: ["name": "Wi-Fi", "enabled": false])
        pump()
        check(item.debugTitle == "Wi-Fi off", "a toggle flashes \"Wi-Fi off\" (got \"\(item.debugTitle)\")")
        pump(3.3)
        preferences.showNetworkName = false
        pump()
        check(item.debugTitle.isEmpty, "the flash clears after about three seconds")
        preferences.showNetworkName = true
        pump()
        let expected = MenuBarText.networkName(monitor.services) ?? ""
        check(item.debugTitle == expected, "the network name setting shows \"\(expected)\" (got \"\(item.debugTitle)\")")
        preferences.showNetworkName = savedShowName

        print(failures == 0 ? "UI SELFTEST PASSED" : "UI SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}

/// Renders real views to PNGs, light and dark, so the UI can be checked without
/// clicking through it.
private enum Snapshots {
    static func write(to dir: URL) -> Int32 {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Every row state: routing, dormant but connected, enabled but down,
        // disabled, settling, and the keyboard highlight.
        let sample = [
            NetworkServiceState(id: "ETH", name: "Thunderbolt Ethernet Slot 0", bsdName: "en7", isEnabled: true,
                                ipv4Address: "10.20.30.45", router: "10.20.30.1", hasActiveLink: true,
                                isPrimary: true, kind: .wired, ssid: nil, orderIndex: 0),
            NetworkServiceState(id: "WIFI", name: "Wi-Fi", bsdName: "en0", isEnabled: true,
                                ipv4Address: "10.20.40.12", router: "10.20.40.1", hasActiveLink: true,
                                isPrimary: false, kind: .wifi, ssid: "Harbor Lane", orderIndex: 2),
            NetworkServiceState(id: "USB", name: "USB 10/100/1000 LAN", bsdName: "en8", isEnabled: true,
                                ipv4Address: nil, router: nil, hasActiveLink: false,
                                isPrimary: false, kind: .wired, ssid: nil, orderIndex: 1),
            NetworkServiceState(id: "VPN", name: "Corp VPN", bsdName: nil, isEnabled: true,
                                ipv4Address: nil, router: nil, hasActiveLink: false,
                                isPrimary: false, kind: .vpn, ssid: nil, orderIndex: 3),
            NetworkServiceState(id: "BR", name: "Thunderbolt Bridge", bsdName: "bridge0", isEnabled: false,
                                ipv4Address: nil, router: nil, hasActiveLink: false,
                                isPrimary: false, kind: .aggregate, ssid: nil, orderIndex: 4),
        ]
        var written = 0
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let live = PopoverViewController(monitor: StatusMonitor(), toggle: ToggleRouter.shared)
            written += render(live.view, to: dir.appendingPathComponent("popover-live-\(suffix).png"), dark: dark)
            written += render(sampleList(sample), to: dir.appendingPathComponent("rows-sample-\(suffix).png"), dark: dark)
            written += renderSettings(to: dir.appendingPathComponent("settings-\(suffix).png"), dark: dark)
        }
        print("wrote \(written) snapshots to \(dir.path)")
        return written == 6 ? 0 : 1
    }

    /// The sample rows, with Wi-Fi highlighted and the VPN settling.
    private static func sampleList(_ services: [NetworkServiceState]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for service in services {
            let row = ServiceRowView(state: service, settling: service.id == "VPN") { _, _ in }
            row.isHighlighted = service.id == "WIFI"
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 256).isActive = true
        }
        return stack
    }

    private static func appearance(dark: Bool) -> NSAppearance {
        NSAppearance(named: dark ? .darkAqua : .aqua)!
    }

    /// Render a view by hosting it in an offscreen window with the given appearance.
    private static func render(_ view: NSView, to url: URL, dark: Bool) -> Int {
        let look = appearance(dark: dark)
        NSApp.appearance = look   // resolves dynamic colors the views read at build time
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = look
        let host = NSView()
        host.appearance = look
        host.wantsLayer = true
        look.performAsCurrentDrawingAppearance {
            host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return capture(host, to: url)
    }

    /// The Settings window is rendered in place: moving its content into another
    /// window would take it out of the real one.
    private static func renderSettings(to url: URL, dark: Bool) -> Int {
        let look = appearance(dark: dark)
        NSApp.appearance = look
        let controller = SettingsWindowController.shared
        controller.window?.appearance = look
        controller.refresh()
        guard let content = controller.window?.contentView else { return 0 }
        // A content view doesn't draw the window background; paint it so text on a
        // transparent capture stays readable. (This process exits right after.)
        content.wantsLayer = true
        look.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        content.layoutSubtreeIfNeeded()
        controller.window?.setContentSize(content.fittingSize)
        content.layoutSubtreeIfNeeded()
        return capture(content, to: url)
    }

    private static func capture(_ view: NSView, to url: URL) -> Int {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))   // let layers and the spinner draw
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return 0 }
        return (try? data.write(to: url)) == nil ? 0 : 1
    }
}
#endif
