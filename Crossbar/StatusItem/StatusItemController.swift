import Cocoa
import Combine

/// Owns the menu bar `NSStatusItem` and the `NSPopover` it toggles.
///
/// This is the surface the rest of the app hangs off of. In later milestones
/// the popover's content view controller gains the live service list (M1) and
/// the wired-up toggles (M2); the status item's icon starts reflecting overall
/// network state (M3). For M0 it's a placeholder icon and an empty popover.
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    /// Long-lived, read-only network state. Kept alive for the whole app so it
    /// keeps receiving SCDynamicStore notifications even while the popover is
    /// closed (the menu bar icon will reflect its state in M3).
    private let monitor = StatusMonitor()

    /// The privileged write path, behind a protocol so the backend can change
    /// without touching the UI.
    private let privilegedToggle: PrivilegedToggle = NetworksetupToggle()

    private var cancellable: AnyCancellable?

    /// Tracks the icon's current alert state so we only regenerate the (drawn)
    /// glyph when it actually flips, not on every published snapshot.
    private var iconShowsAlert: Bool?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient   // closes itself when focus moves elsewhere
        popover.contentViewController = PopoverViewController(monitor: monitor, toggle: privilegedToggle)

        if let button = statusItem.button {
            // Custom globe-with-crossbar template glyph (see StatusBarIcon).
            button.image = StatusBarIcon.image()
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
            .sink { [weak self] services in self?.updateIcon(for: services) }
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring the popover's window forward so it can take key focus even
            // though we're an accessory (non-activating) app.
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
