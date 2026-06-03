import Cocoa

/// One row in the popover: status dot · (name + optional "active route"
/// subtitle) · toggle.
///
/// Flipping the switch invokes `onToggle(desiredEnabled)`. The view doesn't
/// know how the toggle is carried out (that's the `PrivilegedToggle` seam) —
/// it just reports the user's intent and lets the monitor's next snapshot
/// settle the displayed state.
final class ServiceRowView: NSView {
    private let toggleSwitch = NSSwitch()
    /// Reports the user's intent and passes `self` so the controller can freeze
    /// this row's switch while the privileged call is in flight.
    private let onToggle: (Bool, ServiceRowView) -> Void

    init(state: NetworkServiceState, onToggle: @escaping (Bool, ServiceRowView) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let dot = Self.makeDot(for: state.connectivity)

        let nameLabel = NSTextField(labelWithString: state.name)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Name, plus an "active route" subtitle for the one service carrying
        // traffic. Stacking it vertically keeps the full name readable rather
        // than letting an inline badge crowd it into truncation.
        let textStack = NSStackView(views: [nameLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        if let ssid = state.ssid {
            let ssidLabel = NSTextField(labelWithString: ssid)
            ssidLabel.font = .systemFont(ofSize: 10)
            ssidLabel.textColor = .secondaryLabelColor
            ssidLabel.lineBreakMode = .byTruncatingTail
            ssidLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(ssidLabel)
        }
        if state.isPrimary {
            let badge = NSTextField(labelWithString: "active route")
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.textColor = .controlAccentColor
            textStack.addArrangedSubview(badge)
        }

        toggleSwitch.state = state.isEnabled ? .on : .off
        toggleSwitch.controlSize = .small
        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchFlipped)

        // Flexible gap so name hugs the left and the switch sits flush right.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [dot, textStack, spacer, toggleSwitch])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: dot)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])

        // Hover detail (minimal, per spec): route state, IP, router (+ SSID).
        var detail = "Route: \(state.routeState)\nIP: \(state.ipv4Address ?? "—")\nRouter: \(state.router ?? "—")"
        if let ssid = state.ssid {
            detail = "Network: \(ssid)\n" + detail
        }
        toolTip = detail

        // Dim dormant rows — disabled services and enabled-but-down ones (e.g.
        // the Thunderbolt Bridge, an inactive VPN) — so the genuinely live
        // services (the active route and any connected NIC) stand out. A dimmed
        // row is still fully interactive, so the switch remains usable.
        alphaValue = (state.connectivity == .connected) ? 1.0 : 0.5
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Disable the switch (e.g. while a toggle is in flight) so it can't be
    /// re-flipped before the result lands.
    func setToggleEnabled(_ enabled: Bool) {
        toggleSwitch.isEnabled = enabled
    }

    @objc private func switchFlipped() {
        onToggle(toggleSwitch.state == .on, self)
    }

    /// A small filled circle colored by connectivity:
    /// green = connected, yellow = enabled but down, gray = inactive.
    private static func makeDot(for connectivity: NetworkServiceState.Connectivity) -> NSView {
        let color: NSColor
        switch connectivity {
        case .connected:    color = .systemGreen
        case .notConnected: color = .systemYellow
        case .inactive:     color = .tertiaryLabelColor
        }

        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        let dot = NSImageView(image: image?.withSymbolConfiguration(config) ?? NSImage())
        dot.contentTintColor = color
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        return dot
    }
}
