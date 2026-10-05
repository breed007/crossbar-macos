import Cocoa
import Combine

/// Owns the menu bar `NSStatusItem` and the `NSPopover` it toggles, and the text
/// next to the icon: a brief flash after any toggle, and optionally the active
/// network's name (F5).
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    /// Long-lived, read-only network state. Kept alive for the whole app so it
    /// keeps receiving SCDynamicStore notifications even while the popover is
    /// closed (the menu bar icon will reflect its state in M3).
    private let monitor = StatusMonitor()

    /// The privileged write path. `ToggleRouter` picks Backend B (the helper) when
    /// installed and falls back to Backend A (networksetup) otherwise — behind the
    /// `PrivilegedToggle` protocol so the UI never knows which ran.
    private let toggleRouter = ToggleRouter.shared

    private var cancellable: AnyCancellable?
    private let preferences = Preferences()
    private var observers: [NSObjectProtocol] = []
    /// Pending end of a flash; nil when not flashing.
    private var flashReset: DispatchWorkItem?
    private var popoverController: PopoverViewController? {
        popover.contentViewController as? PopoverViewController
    }

    /// Tracks the icon's current alert state so we only regenerate the (drawn)
    /// glyph when it actually flips, not on every published snapshot.
    private var iconShowsAlert: Bool?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient   // closes itself when focus moves elsewhere
        popover.delegate = self
        let controller = PopoverViewController(monitor: monitor, toggle: toggleRouter)
        controller.onClose = { [weak self] in self?.popover.performClose(nil) }
        controller.onOpenSettings = { SettingsWindowController.shared.show() }
        popover.contentViewController = controller

        if let button = statusItem.button {
            // Custom nodes-on-a-crossbar template glyph (see StatusBarIcon).
            button.image = StatusBarIcon.image()
            button.imagePosition = .imageOnly
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Reflect overall state in the menu bar. We only alert when there's no
        // active route at all — i.e. nothing is currently carrying traffic —
        // which is a genuine "attention needed" signal. Badging on "any service
        // disabled" would be permanently lit on the many Macs that ship with an
        // inactive service (e.g. a stale Thunderbolt Bridge), defeating its use.
        cancellable = monitor.$services
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] services in
                self?.updateIcon(for: services)
                if self?.flashReset == nil { self?.updateTitle() }
            }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .crossbarServiceToggled, object: nil, queue: .main) { [weak self] note in
            guard let name = note.userInfo?["name"] as? String,
                  let enabled = note.userInfo?["enabled"] as? Bool else { return }
            self?.flash(MenuBarText.toggled(name: name, enabled: enabled))
        })
        observers.append(center.addObserver(forName: .crossbarPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            if self?.flashReset == nil { self?.updateTitle() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Menu bar text (F5)

    #if DEBUG
    /// For `--ui-selftest`: the text currently next to the icon.
    var debugTitle: String { statusItem.button?.title.trimmingCharacters(in: .whitespaces) ?? "" }
    var debugPopover: PopoverViewController? { popoverController }
    #endif

    /// Show `text`, or the active network's name if that setting is on, or nothing.
    private func updateTitle(_ text: String? = nil) {
        guard let button = statusItem.button else { return }
        let title = text ?? (preferences.showNetworkName ? MenuBarText.networkName(monitor.services) : nil)
        button.title = title.map { " " + $0 } ?? ""
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
    }

    /// Show what just changed for about three seconds, then go back to the usual
    /// title.
    private func flash(_ text: String) {
        flashReset?.cancel()
        updateTitle(text)
        let reset = DispatchWorkItem { [weak self] in
            self?.flashReset = nil
            self?.updateTitle()
        }
        flashReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: reset)
    }

    private func updateIcon(for services: [NetworkServiceState]) {
        // "Needs attention" = there are services but none is the active route.
        // An empty list (e.g. transient during refresh) is not treated as alert.
        let hasActiveRoute = services.contains { $0.isPrimary }
        let alert = !services.isEmpty && !hasActiveRoute

        statusItem.button?.toolTip = alert
            ? "Crossbar — no network is currently routing traffic"
            : "Crossbar"

        // Only redraw the glyph when the alert state actually changes.
        guard iconShowsAlert != alert else { return }
        iconShowsAlert = alert
        statusItem.button?.image = StatusBarIcon.image(alert: alert)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // First open is a natural, in-context moment to ask for Wi-Fi SSID
            // access (no-op after the first time / once decided).
            monitor.requestWiFiAccessIfNeeded()
            popoverController?.prepareToShow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring the popover's window forward so it can take key focus even
            // though we're an accessory (non-activating) app, then focus the list
            // so the arrow keys work right away (F7).
            popover.contentViewController?.view.window?.makeKey()
            popoverController?.focus()
        }
    }
}

#if DEBUG
extension StatusItemController {
    private static var demoBackdrop: NSWindow?

    /// Open one piece of UI with sample data for a screenshot (debug flag `--demo`):
    /// `popover`, `warning` (the route warning), or `settings`.
    func debugDemo(_ what: String) {
        // A backdrop in GitHub's page color, above everything else on screen (menu bar
        // included) and just below the captured UI. The script captures the composited
        // screen region, so the popover's material blends with this, as it would with
        // a desktop, instead of with the real screen, and the image blends into the
        // README.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let backdrop = NSWindow(contentRect: NSScreen.main?.frame ?? .zero, styleMask: .borderless,
                                backing: .buffered, defer: false)
        backdrop.title = "CrossbarDemoBackdrop"   // the capture script skips it by name
        backdrop.backgroundColor = DemoData.backdropColor(dark: dark)
        // NSAlert sets its window to the modal-panel level when it runs, and main-queue
        // work doesn't run inside its modal loop, so for the warning the backdrop goes
        // below that level from the start.
        let below = what == "warning" ? NSWindow.Level.modalPanel : NSWindow.Level.popUpMenu
        backdrop.level = NSWindow.Level(rawValue: below.rawValue - 1)
        backdrop.ignoresMouseEvents = true
        backdrop.orderFrontRegardless()
        Self.demoBackdrop = backdrop

        switch what {
        case "warning":
            // Turning off the active route when Wi-Fi can take over.
            let prediction = RoutePrediction.disabling("demo-ethernet", in: DemoData.services)
            let plan = ToggleConfirmation.plan(serviceName: "Ethernet", prediction: prediction,
                                               remoteSessions: [], confirmHandoff: true)
            MainActor.assumeIsolated { _ = plan?.confirm() }   // debugDemo runs on the main queue
        case "settings":
            SettingsWindowController.shared.show()
            SettingsWindowController.shared.window?.level = DemoData.uiLevel
        default:
            // A popover anchored to the menu bar takes the menu bar's appearance (the
            // system's), not the app's; force the requested one for the screenshot.
            popover.appearance = NSApp.appearance
            statusItem.button?.performClick(nil)   // opens the popover
            if let window = popover.contentViewController?.view.window {
                if window.level.rawValue <= backdrop.level.rawValue { window.level = DemoData.uiLevel }
                FileHandle.standardError.write(Data("popover level \(window.level.rawValue), backdrop \(backdrop.level.rawValue)\n".utf8))
            }
        }
    }
}
#endif
