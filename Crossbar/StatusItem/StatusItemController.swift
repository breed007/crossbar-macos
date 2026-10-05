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
