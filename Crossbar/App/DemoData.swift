#if DEBUG
import AppKit

/// Sample data for README screenshots (`Crossbar --demo`, see scripts/screenshots.sh).
/// With `active` set, the real popover, route warning, and Settings window show these
/// instead of this Mac's services, addresses, Wi-Fi network, and VPN names, so nothing
/// real ends up in a picture. Debug builds only; compiled out of releases.
enum DemoData {
    static var active = false

    /// Private (RFC 1918) addresses and made-up names, not this Mac's. Already in the
    /// popover's display order (wired, Wi-Fi, VPN, bridge).
    static let services: [NetworkServiceState] = [
        NetworkServiceState(id: "demo-ethernet", name: "Ethernet", bsdName: "en7", isEnabled: true,
                            ipv4Address: "10.20.30.45", router: "10.20.30.1", hasActiveLink: true,
                            isPrimary: true, kind: .wired, ssid: nil, orderIndex: 0),
        NetworkServiceState(id: "demo-wifi", name: "Wi-Fi", bsdName: "en0", isEnabled: true,
                            ipv4Address: "10.20.40.12", router: "10.20.40.1", hasActiveLink: true,
                            isPrimary: false, kind: .wifi, ssid: "Harbor Lane", orderIndex: 1),
        NetworkServiceState(id: "demo-vpn", name: "Corp VPN", bsdName: nil, isEnabled: true,
                            ipv4Address: nil, router: nil, hasActiveLink: false,
                            isPrimary: false, kind: .vpn, ssid: nil, orderIndex: 2),
        NetworkServiceState(id: "demo-bridge", name: "Thunderbolt Bridge", bsdName: "bridge0", isEnabled: false,
                            ipv4Address: nil, router: nil, hasActiveLink: false,
                            isPrimary: false, kind: .aggregate, ssid: nil, orderIndex: 3),
    ]

    /// Settings in demo mode come from here, never from the real app's defaults (the
    /// Debug build shares `com.breed.Crossbar`'s), so the demo can't read or change them.
    static let defaults: UserDefaults = {
        let name = "com.breed.Crossbar.demo"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }()

    /// GitHub's README background, light and dark, so captures blend into the page.
    static func backdropColor(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0x0d / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1) : .white
    }

    /// Captured windows sit here, above the backdrop (which sits just below menus).
    static let uiLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue)
}
#endif
