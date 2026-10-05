import Cocoa

/// The Settings window (F6): Launch at Login, the menu bar name, the handoff
/// confirmation, and the privileged helper's status. Built in code, like the rest
/// of the UI.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let preferences = Preferences()
    private let helper = HelperClient()

    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let launchNote = SettingsWindowController.note("")
    private let showName = NSButton(checkboxWithTitle: "Show network name in menu bar", target: nil, action: nil)
    private let confirmHandoff = NSButton(checkboxWithTitle: "Ask before moving traffic to another service",
                                          target: nil, action: nil)
    private let helperStatus = NSTextField(labelWithString: "")
    private let setUpButton = NSButton(title: "Set Up…", target: nil, action: nil)
    private let loginItemsButton = NSButton(title: "Open Login Items", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Crossbar Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    // Approval happens in System Settings; re-read when the user comes back.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    // MARK: - Layout

    private func buildContent() {
        for (button, action) in [(launchAtLogin, #selector(toggleLaunchAtLogin)),
                                 (showName, #selector(toggleShowName)),
                                 (confirmHandoff, #selector(toggleConfirmHandoff)),
                                 (setUpButton, #selector(setUpHelper)),
                                 (loginItemsButton, #selector(openLoginItems)),
                                 (removeButton, #selector(removeHelper))] {
            button.target = self
            button.action = action
        }
        setUpButton.bezelStyle = .push
        loginItemsButton.bezelStyle = .push
        removeButton.bezelStyle = .push
        helperStatus.font = .systemFont(ofSize: 13)

        let helperButtons = NSStackView(views: [setUpButton, loginItemsButton, removeButton])
        helperButtons.spacing = 8

        let stack = NSStackView(views: [
            Self.heading("General"),
            launchAtLogin, launchNote,
            showName,
            confirmHandoff,
            Self.note("Crossbar always asks before a change would leave you offline or drop a remote session."),
            Self.heading("Passwordless Toggling"),
            helperStatus,
            helperButtons,
            Self.note("Without the helper, Crossbar uses the sudo rule described in the README."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[5])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 420),
        ])
        window?.contentView = content
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 372
        return label
    }

    // MARK: - State

    /// Re-read everything. Login items and the helper are approved outside the app,
    /// so their state is read fresh rather than cached.
    func refresh() {
        launchAtLogin.state = LoginItem.isEnabled ? .on : .off
        launchNote.stringValue = LoginItem.requiresApproval
            ? "Waiting for approval in System Settings → General → Login Items & Extensions." : ""
        launchNote.isHidden = launchNote.stringValue.isEmpty
        showName.state = preferences.showNetworkName ? .on : .off
        confirmHandoff.state = preferences.confirmRouteHandoff ? .on : .off

        let status = helper.status
        switch status {
        case .enabled:
            helperStatus.stringValue = "Active. Crossbar turns services on and off without a password."
        case .requiresApproval:
            helperStatus.stringValue = "Waiting for approval in Login Items & Extensions."
        case .notRegistered, .notFound:
            helperStatus.stringValue = "Not set up."
        }
        setUpButton.isHidden = status == .enabled
        loginItemsButton.isHidden = status != .requiresApproval
        removeButton.isHidden = status == .notRegistered || status == .notFound
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        let wantOn = launchAtLogin.state == .on
        do {
            try LoginItem.setEnabled(wantOn)
        } catch {
            if !(wantOn && LoginItem.requiresApproval) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t change “Launch at Login”"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window!)
            }
        }
        if wantOn && LoginItem.requiresApproval { HelperClient.openLoginItemsSettings() }
        refresh()
    }

    @objc private func toggleShowName() {
        preferences.showNetworkName = showName.state == .on
    }

    @objc private func toggleConfirmHandoff() {
        preferences.confirmRouteHandoff = confirmHandoff.state == .on
    }

    @objc private func setUpHelper() {
        HelperSetup.run(helper)
        refresh()
    }

    @objc private func openLoginItems() {
        HelperClient.openLoginItemsSettings()
    }

    @objc private func removeHelper() {
        let alert = NSAlert()
        alert.messageText = "Remove Crossbar’s helper?"
        alert.informativeText = "Crossbar will go back to using the sudo rule, if you have one installed."
        let remove = alert.addButton(withTitle: "Remove")
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.helper.unregister()
            } catch {
                let failure = NSAlert(error: error)
                failure.beginSheetModal(for: self.window!)
            }
            self.refresh()
        }
    }
}
