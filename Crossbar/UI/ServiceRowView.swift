import Cocoa

/// One row in the popover: status glyph · name (plus SSID, "active route", or
/// "Connecting…" subtitles) · toggle.
///
/// Flipping the switch invokes `onToggle(desiredEnabled, self)`. The view doesn't
/// know how the toggle is carried out (that's the `PrivilegedToggle` seam); it
/// reports the user's intent and lets the monitor's next snapshot settle the state.
final class ServiceRowView: NSView {
    let serviceID: String
    private let toggleSwitch = NSSwitch()
    private let content: NSStackView
    private var routeBadge: NSTextField?
    /// Reports the user's intent and passes `self` so the controller can freeze
    /// this row's switch while the privileged call is in flight.
    private let onToggle: (Bool, ServiceRowView) -> Void

    /// Keyboard selection (F7). Drawn behind the row; not dimmed with it.
    var isHighlighted = false {
        didSet {
            layer?.backgroundColor = isHighlighted
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
                : nil
        }
    }

    init(state: NetworkServiceState, settling: Bool = false,
         onToggle: @escaping (Bool, ServiceRowView) -> Void) {
        self.serviceID = state.id
        self.onToggle = onToggle

        let glyph: NSView = settling ? Self.makeSpinner() : Self.makeDot(for: state.connectivity)

        let nameLabel = NSTextField(labelWithString: state.name)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Name, plus subtitles. Stacking them vertically keeps the full name
        // readable rather than letting an inline badge crowd it into truncation.
        let textStack = NSStackView(views: [nameLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        if settling {
            textStack.addArrangedSubview(Self.subtitle("Connecting…", color: .secondaryLabelColor))
        } else if let ssid = state.ssid {
            let ssidLabel = Self.subtitle(ssid, color: .secondaryLabelColor)
            ssidLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(ssidLabel)
        }
        var badge: NSTextField?
        if state.isPrimary {
            let label = Self.subtitle("active route", color: .controlAccentColor, weight: .semibold)
            textStack.addArrangedSubview(label)
            badge = label
        }

        toggleSwitch.state = state.isEnabled ? .on : .off
        toggleSwitch.controlSize = .small

        // Flexible gap so the name hugs the left and the switch sits flush right.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        content = NSStackView(views: [glyph, textStack, spacer, toggleSwitch])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        routeBadge = badge
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchFlipped)
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

        // Hover detail (minimal, per spec): the full name (recoverable when the
        // label truncates), then route state, IP, router (+ SSID).
        var detail = "\(state.name)\nRoute: \(state.routeState)\nIP: \(state.ipv4Address ?? "—")\nRouter: \(state.router ?? "—")"
        if let ssid = state.ssid { detail += "\nNetwork: \(ssid)" }
        toolTip = detail

        // Dim dormant rows (disabled, or enabled but down) so the live services
        // stand out. A settling row isn't dimmed: something is happening. Only the
        // content dims, so the keyboard highlight stays visible, and a dimmed row
        // is still fully interactive.
        content.alphaValue = (state.connectivity == .connected || settling) ? 1.0 : 0.5

        // Accessibility: status is shown by glyph shape and color, so give the row
        // a spoken label carrying the full state, and label the switch.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.accessibilityLabel(for: state, settling: settling))
        toggleSwitch.setAccessibilityLabel("\(state.name), \(state.isEnabled ? "on" : "off")")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A spoken description of a row's full state, e.g.
    /// "Wi-Fi, connected, active route, network MI6".
    static func accessibilityLabel(for state: NetworkServiceState, settling: Bool = false) -> String {
        let status: String
        if settling {
            status = "connecting"
        } else {
            switch state.connectivity {
            case .connected:    status = "connected"
            case .notConnected: status = "enabled but not connected"
            case .inactive:     status = "disabled"
            }
        }
        var parts = [state.name, status]
        if state.isPrimary { parts.append("active route") }
        if let ssid = state.ssid { parts.append("network \(ssid)") }
        return parts.joined(separator: ", ")
    }

    /// Disable the switch (e.g. while a toggle is in flight) so it can't be
    /// re-flipped before the result lands.
    func setToggleEnabled(_ enabled: Bool) {
        toggleSwitch.isEnabled = enabled
    }

    /// Force the switch to a known position — used to revert an optimistic flip
    /// when a toggle fails or is canceled (no model change, so no rebuild lands).
    func setToggleOn(_ isOn: Bool) {
        toggleSwitch.state = isOn ? .on : .off
    }

    var isToggleEnabled: Bool { toggleSwitch.isEnabled }

    /// Flip the switch as if clicked: the keyboard path (F7).
    func flipFromKeyboard() {
        guard toggleSwitch.isEnabled else { return }
        toggleSwitch.state = toggleSwitch.state == .on ? .off : .on
        switchFlipped()
    }

    /// The traffic just moved to this service: fade its "active route" badge in, so
    /// the move is visible rather than a silent reshuffle.
    func animateRouteArrival() {
        guard let routeBadge else { return }
        routeBadge.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            routeBadge.animator().alphaValue = 1
        }
    }

    @objc private func switchFlipped() {
        onToggle(toggleSwitch.state == .on, self)
    }

    private static func subtitle(_ text: String, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func makeSpinner() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 11),
            spinner.heightAnchor.constraint(equalToConstant: 11),
        ])
        spinner.setAccessibilityElement(false)
        return spinner
    }

    /// A small status glyph. Color AND shape both encode connectivity, so it stays
    /// distinguishable for color-blind users:
    ///   connected → filled circle (green)
    ///   enabled but down → hollow circle (yellow)
    ///   disabled → circle with a slash (gray)
    private static func makeDot(for connectivity: NetworkServiceState.Connectivity) -> NSView {
        let color: NSColor
        let symbol: String
        switch connectivity {
        case .connected:    color = .systemGreen;         symbol = "circle.fill"
        case .notConnected: color = .systemYellow;        symbol = "circle"
        case .inactive:     color = .tertiaryLabelColor;  symbol = "circle.slash"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        let dot = NSImageView(image: image?.withSymbolConfiguration(config) ?? NSImage())
        dot.contentTintColor = color
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setAccessibilityElement(false)   // status is spoken via the row label
        return dot
    }
}
