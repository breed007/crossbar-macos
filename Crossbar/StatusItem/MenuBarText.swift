import Foundation

/// The text shown next to the menu bar icon (F5).
enum MenuBarText {
    static let maxLength = 16

    /// The active network's name: the SSID when Wi-Fi carries traffic, otherwise the
    /// service name. Nil when nothing does (the icon's alert badge covers that).
    static func networkName(_ services: [NetworkServiceState]) -> String? {
        guard let active = services.first(where: \.isPrimary) else { return nil }
        let name = (active.kind == .wifi ? active.ssid : nil) ?? active.name
        return truncate(name)
    }

    /// The flash after a toggle, e.g. "Wi-Fi off".
    static func toggled(name: String, enabled: Bool) -> String {
        "\(truncate(name)) \(enabled ? "on" : "off")"
    }

    static func truncate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
