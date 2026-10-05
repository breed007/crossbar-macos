import Cocoa
import Combine

/// Popover contents: a title, one `ServiceRowView` per network service, and a
/// footer. Rebuilt whenever the `StatusMonitor` publishes a new snapshot. Turns
/// switch flips and key presses into privileged calls through `PrivilegedToggle`.
final class PopoverViewController: NSViewController {
    /// Set by `StatusItemController`.
    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?

    private let monitor: StatusMonitor
    private let toggle: PrivilegedToggle
    private let helperClient = HelperClient()
    private let preferences = Preferences()
    private var cancellable: AnyCancellable?

    /// Service IDs with a toggle in flight, so a second flip on the same row before
    /// the first completes is ignored. Keyed by ID: two services can share a name.
    private var inFlight: Set<String> = []
    /// Services just turned on that are still coming up (F4).
    private var settling = SettlingTracker()
    /// The keyboard selection (F7), by service ID so it survives rebuilds.
    private var highlightedID: String?
    private var rows: [ServiceRowView] = []
    /// For fading in the "active route" badge when traffic moves to another row.
    private var lastPrimaryID: String?
    private var hasRendered = false

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
        let container = KeyHandlingView()
        container.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
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

    /// Called just before the popover opens: clear the keyboard selection and
    /// rebuild, so the footer reflects any helper change made in Settings.
    func prepareToShow() {
        highlightedID = nil
        rebuild(with: monitor.services)
    }

    /// Take keyboard focus once the popover's window is key.
    func focus() {
        view.window?.makeFirstResponder(view)
    }

    // MARK: - Building the list

    private func rebuild(with services: [NetworkServiceState]) {
        settling.prune(services)
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rows = []

        let title = NSTextField(labelWithString: "Network Services")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(title)

        if services.isEmpty {
            let empty = NSTextField(labelWithString: "No network services found")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .tertiaryLabelColor
            contentStack.addArrangedSubview(empty)
        }
        for service in services {
            let row = ServiceRowView(state: service, settling: settling.isSettling(service.id)) { [weak self] desiredEnabled, row in
                self?.handleToggle(serviceID: service.id, enable: desiredEnabled, row: row)
            }
            // A row whose toggle is mid-flight stays disabled until it lands.
            row.setToggleEnabled(!inFlight.contains(service.id))
            row.isHighlighted = service.id == highlightedID
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            rows.append(row)
        }
        if highlightedID != nil, !services.contains(where: { $0.id == highlightedID }) { highlightedID = nil }

        // Traffic moved to another service: make the badge's move visible.
        let primaryID = services.first(where: \.isPrimary)?.id
        if hasRendered, let primaryID, primaryID != lastPrimaryID {
            rows.first { $0.serviceID == primaryID }?.animateRouteArrival()
        }
        lastPrimaryID = primaryID
        hasRendered = true

        addFooter()

        // Size the popover to fit the current contents.
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.contentWidth, height: view.fittingSize.height)
    }

    /// Set Up Passwordless Toggling… until the helper is enabled, then Settings…,
    /// Network Settings…, and Quit (F6). Everything else lives in Settings.
    private func addFooter() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        if !helperClient.isEnabled {
            let setup = makeFooterButton(title: "Set Up Passwordless Toggling…", action: #selector(setUpHelper))
            setup.contentTintColor = .controlAccentColor
            contentStack.addArrangedSubview(setup)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [
            makeFooterButton(title: "Settings…", action: #selector(openSettings)),
            makeFooterButton(title: "Network Settings…", action: #selector(openNetworkSettings)),
            spacer,
            makeFooterButton(title: "Quit", action: #selector(quit)),
        ])
        footer.orientation = .horizontal
        footer.spacing = 10
        contentStack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
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

    // MARK: - Keyboard (F7)

    /// Up and Down move the highlight; Space or Return toggles the highlighted
    /// service through the same checks as a click; Escape closes the popover.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: moveHighlight(by: 1); return true      // down arrow
        case 126: moveHighlight(by: -1); return true     // up arrow
        case 49, 36, 76:                                  // space, return, enter
            rows.first { $0.serviceID == highlightedID }?.flipFromKeyboard()
            return highlightedID != nil
        case 53: onClose?(); return true                  // escape
        default: return false
        }
    }

    private func moveHighlight(by step: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.serviceID == highlightedID }
        let next: Int
        if let current {
            next = min(max(current + step, 0), rows.count - 1)
        } else {
            next = step > 0 ? 0 : rows.count - 1
        }
        highlightedID = rows[next].serviceID
        for row in rows { row.isHighlighted = row.serviceID == highlightedID }
    }

    // MARK: - Toggling

    private func handleToggle(serviceID: String, enable: Bool, row: ServiceRowView) {
        // Security hygiene: only drive the privileged path with a service that is in
        // the *current* live enumerated set. Rows are built from that set, but the
        // snapshot can change underneath us.
        guard let service = monitor.services.first(where: { $0.id == serviceID }) else {
            monitor.refreshNow()
            return
        }
        guard !inFlight.contains(serviceID) else { return }
        row.setToggleOn(enable)

        // F3: before turning off the service carrying traffic, say what happens.
        if !enable {
            let prediction = RoutePrediction.disabling(serviceID, in: monitor.services)
            let remote = prediction == .notActiveRoute ? [] : RemoteSessions.current()
            if let confirmation = ToggleConfirmation.plan(serviceName: service.name, prediction: prediction,
                                                          remoteSessions: remote,
                                                          confirmHandoff: preferences.confirmRouteHandoff),
               !confirmation.confirm(preferences) {
                row.setToggleOn(service.isEnabled)   // canceled: put the switch back
                return
            }
        }

        inFlight.insert(serviceID)
        // Freeze the just-clicked switch so a rapid second click can't visually flip
        // it back while the first call is still in flight.
        row.setToggleEnabled(false)

        Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = false
            defer {
                self.inFlight.remove(serviceID)
                if succeeded {
                    // The system state changed, so refreshNow() publishes a different
                    // snapshot and rebuild() replaces this row with a fresh one.
                    if enable { self.scheduleSettling(serviceID) }
                    self.monitor.refreshNow()
                    NotificationCenter.default.post(name: .crossbarServiceToggled, object: nil,
                                                    userInfo: ["name": service.name, "enabled": enable])
                } else {
                    // FAILURE: the model is unchanged, so refreshNow() would publish an
                    // equal snapshot that removeDuplicates() drops. No rebuild would
                    // land and the frozen row would stay stuck, so restore it here.
                    row.setToggleOn(service.isEnabled)
                    row.setToggleEnabled(true)
                }
            }
            do {
                try await self.toggle.setEnabled(enable, serviceID: serviceID, serviceName: service.name)
                succeeded = true
            } catch {
                self.presentToggleError(error, serviceName: service.name)
            }
        }
    }

    /// Show "Connecting…" until the service connects or the window runs out. The
    /// timeout needs its own rebuild: if nothing else changes, no snapshot arrives.
    private func scheduleSettling(_ serviceID: String) {
        settling.begin(serviceID)
        DispatchQueue.main.asyncAfter(deadline: .now() + SettlingTracker.window + 0.5) { [weak self] in
            guard let self, self.settling.isSettling(serviceID) else { return }
            self.rebuild(with: self.monitor.services)
        }
    }

    private func presentToggleError(_ error: Error, serviceName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t change “\(serviceName)”"
        alert.informativeText = error.localizedDescription

        if case PrivilegedToggleError.sudoRuleMissing = error {
            alert.informativeText += "\n\nTo use the sudo rule instead, run:\n\n"
                + "sudo visudo -f /etc/sudoers.d/crossbar\n\n"
                + "and add this line:\n\n"
                + "\(NSUserName()) ALL=(root) NOPASSWD: /usr/sbin/networksetup -setnetworkserviceenabled *"
            alert.addButton(withTitle: "Set Up Passwordless Toggling…")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { setUpHelper() }
            return
        }
        alert.addButton(withTitle: "OK")
        // Accessory apps aren't active by default; bring the alert forward.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Footer actions

    @objc private func setUpHelper() {
        HelperSetup.run(helperClient)
        // The service list didn't change, so the monitor's next snapshot would be
        // deduplicated away. Rebuild directly so the footer shows the new status.
        rebuild(with: monitor.services)
    }

    @objc private func openSettings() {
        onClose?()
        onOpenSettings?()
    }

    /// Opens the native Network settings pane, for the detail Crossbar omits.
    @objc private func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// The popover's root view: takes keyboard focus and hands key presses to the
/// controller. Unhandled keys go up the responder chain as usual.
final class KeyHandlingView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }
}
