import Cocoa
import Combine

/// Popover contents: a title and one `ServiceRowView` per network service,
/// rebuilt whenever the `StatusMonitor` publishes a new snapshot. Owns the
/// `PrivilegedToggle` and translates switch flips into privileged calls.
final class PopoverViewController: NSViewController {
    private let monitor: StatusMonitor
    private let toggle: PrivilegedToggle
    /// Non-nil when the toggle is a router that can install the privileged helper
    /// — used to offer the "Set up helper" affordance and reflect its status.
    private var router: ToggleRouter? { toggle as? ToggleRouter }
    private var cancellable: AnyCancellable?

    /// Service names with a toggle currently in flight, so a second flip on the
    /// same row before the first completes is ignored.
    private var inFlight: Set<String> = []

    private let contentStack = NSStackView()
    private static let contentWidth: CGFloat = 280
    private static let inset: CGFloat = 12

    init(monitor: StatusMonitor, toggle: PrivilegedToggle) {
        self.monitor = monitor
        self.toggle = toggle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = NSView()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.inset),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild(with: monitor.services)
        // Live updates: rebuild only when the snapshot actually changes, so an
        // unrelated network blip doesn't tear down rows mid-hover.
        cancellable = monitor.$services
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.rebuild(with: $0) }
    }

    private func rebuild(with services: [NetworkServiceState]) {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let title = NSTextField(labelWithString: "Network Services")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(title)

        if services.isEmpty {
            let empty = NSTextField(labelWithString: "No network services found")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .tertiaryLabelColor
            contentStack.addArrangedSubview(empty)
        } else {
            for service in services {
                let row = ServiceRowView(state: service) { [weak self] desiredEnabled, row in
                    self?.handleToggle(service: service, enable: desiredEnabled, row: row)
                }
                // A row whose toggle is mid-flight stays disabled until it lands.
                row.setToggleEnabled(!inFlight.contains(service.name))
                contentStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
        }

        // Footer: a separator, a "Launch at Login" checkbox, then a deep link to
        // the native Network settings (for the full data we deliberately omit)
        // and a Quit action.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let launchToggle = NSButton(checkboxWithTitle: "Launch at Login",
                                    target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchToggle.font = .systemFont(ofSize: 11)
        launchToggle.state = LoginItem.isEnabled ? .on : .off
        contentStack.addArrangedSubview(launchToggle)

        // Helper status / setup. When the privileged helper (Backend B) isn't
        // installed, offer to set it up (removes the need for the sudoers rule).
        // When it's active, show a subtle confirmation instead.
        if let router {
            if router.usingHelper {
                let active = NSTextField(labelWithString: "✓ Passwordless toggling active")
                active.font = .systemFont(ofSize: 11)
                active.textColor = .secondaryLabelColor
                contentStack.addArrangedSubview(active)
            } else {
                let setup = makeFooterButton(title: "Set up passwordless toggling…",
                                             action: #selector(setUpHelper))
                setup.contentTintColor = .controlAccentColor
                contentStack.addArrangedSubview(setup)
            }
        }

        let settingsButton = makeFooterButton(title: "Network Settings…",
                                              action: #selector(openNetworkSettings))
        let quitButton = makeFooterButton(title: "Quit", action: #selector(quit))
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [settingsButton, footerSpacer, quitButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        contentStack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        // Size the popover to fit the current contents.
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.contentWidth, height: view.fittingSize.height)
    }

    private func makeFooterButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    /// Opens the native Network settings pane — for when the full detail we
    /// deliberately omit (subnet, DNS, IPv6, …) is actually wanted.
    @objc private func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let wantOn = sender.state == .on
        do {
            try LoginItem.setEnabled(wantOn)
            // If macOS parked the request pending user approval, the login item
            // isn't actually on yet — reflect that and point the user at Settings.
            if wantOn && LoginItem.requiresApproval {
                sender.state = .off
                presentLoginApprovalNeeded()
            }
        } catch {
            // Revert the checkbox to the true state and surface why.
            sender.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t change “Launch at Login”"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func setUpHelper() {
        guard let router else { return }
        do {
            try router.helper.install()
            let alert = NSAlert()
            alert.alertStyle = .informational
            if router.helper.requiresApproval {
                alert.messageText = "One more step"
                alert.informativeText = "Enable Crossbar’s background item under System "
                    + "Settings → General → Login Items & Extensions to finish setting up "
                    + "passwordless toggling."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                alert.messageText = "Passwordless toggling is set up"
                alert.informativeText = "Crossbar can now enable and disable network "
                    + "services without the sudo rule."
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            monitor.refreshNow()   // refresh footer to reflect new status
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t set up the helper"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func presentLoginApprovalNeeded() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Approval needed"
        alert.informativeText = "Turn on Crossbar under System Settings → General → "
            + "Login Items & Extensions to have it launch at login."
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleToggle(service: NetworkServiceState, enable: Bool, row: ServiceRowView) {
        // Security hygiene: only ever drive the privileged path with a name that
        // is present in the *current* live enumerated set. Rows are built from
        // that set, but we re-check in case the snapshot changed underneath us.
        guard monitor.services.contains(where: { $0.name == service.name }) else {
            monitor.refreshNow()
            return
        }
        guard !inFlight.contains(service.name) else { return }
        inFlight.insert(service.name)
        // Freeze the just-clicked switch immediately so a rapid second click
        // can't visually flip it back while the first call is still in flight.
        row.setToggleEnabled(false)

        Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = false
            defer {
                self.inFlight.remove(service.name)
                if succeeded {
                    // The system state changed, so refreshNow() publishes a
                    // *different* snapshot → rebuild() replaces this row with a
                    // fresh, correctly-positioned one. Nothing to do to the row.
                    self.monitor.refreshNow()
                } else {
                    // FAILURE: the model is unchanged, so refreshNow() would
                    // publish an equal snapshot that removeDuplicates() drops —
                    // no rebuild lands, and the row we froze above would stay
                    // stuck showing the wrong position. So revert and re-enable
                    // this row directly, to its true (unchanged) state.
                    row.setToggleOn(service.isEnabled)
                    row.setToggleEnabled(true)
                }
            }
            do {
                try await self.toggle.setEnabled(enable, serviceID: service.id, serviceName: service.name)
                succeeded = true
            } catch {
                self.presentToggleError(error, serviceName: service.name)
            }
        }
    }

    private func presentToggleError(_ error: Error, serviceName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t change “\(serviceName)”"
        alert.informativeText = error.localizedDescription

        if case PrivilegedToggleError.sudoRuleMissing = error {
            alert.informativeText += "\n\nInstall it once with:\n\n"
                + "sudo visudo -f /etc/sudoers.d/crossbar\n\n"
                + "then add this line:\n\n"
                + "\(NSUserName()) ALL=(root) NOPASSWD: /usr/sbin/networksetup -setnetworkserviceenabled *"
        }
        alert.addButton(withTitle: "OK")

        // Accessory apps aren't active by default; bring the alert forward.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
