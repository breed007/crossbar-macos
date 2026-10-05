import Foundation
import Combine
import SystemConfiguration

/// Read-only, event-driven view of the Mac's network services.
///
/// Two halves of the SystemConfiguration framework are in play here, and the
/// distinction matters:
///
///   - **SCPreferences** holds the *configured* set of services and their
///     persisted attributes — name, backing interface, and crucially the
///     enabled flag (`SCNetworkServiceGetEnabled`), which is what "Make Service
///     Inactive" flips. This is the identity layer.
///
///   - **SCDynamicStore** holds *live* runtime state — assigned IP addresses,
///     link up/down, and which service currently owns the default route. It
///     also delivers change notifications, so we never poll: we register for
///     the keys we care about and re-read everything when any of them change.
///
/// `services` is the single `@Published` snapshot the UI binds to.
///
/// **Visible set.** `SCNetworkSetCopyServices` returns *every* configured
/// service, including entries System Settings hides (the internal Apple silicon
/// USB-C interfaces, "Ethernet Adapter (en4)" and friends). `HiddenInterfaces`
/// reads the same `HiddenConfiguration` flag System Settings uses, so the list
/// matches it without running `networksetup`. A refresh is a handful of
/// SystemConfiguration reads, so it runs synchronously on the main thread.
final class StatusMonitor: ObservableObject {
    @Published private(set) var services: [NetworkServiceState] = []

    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var refreshScheduled = false

    /// Supplies the connected Wi-Fi SSID (needs Location Services; see the type).
    private let wifiProvider = WiFiSSIDProvider()

    init() {
        store = makeDynamicStore()
        // Re-read once location access is granted so the SSID can appear.
        wifiProvider.onAuthorizationChange = { [weak self] in self?.refresh() }
        refresh()
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    /// Force an immediate re-read and publish. Used after a toggle to resync the
    /// UI to the real state right away (and to revert an optimistic switch if the
    /// toggle failed), rather than waiting on the SCDynamicStore notification.
    func refreshNow() {
        refresh()
    }

    /// Ask for Wi-Fi SSID access (Location Services) if not yet decided. Called
    /// when the user first opens the popover, so the prompt has context rather
    /// than firing unprompted at launch.
    func requestWiFiAccessIfNeeded() {
        wifiProvider.requestAccessIfNeeded()
    }

    // MARK: - SCDynamicStore setup

    private func makeDynamicStore() -> SCDynamicStore? {
        // Pass `self` to the C callback as an opaque pointer. The monitor lives
        // for the app's lifetime (owned by StatusItemController), so an
        // unretained reference is safe and avoids a retain cycle.
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<StatusMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.scheduleRefresh()
        }

        guard let store = SCDynamicStoreCreate(
            nil, "com.breed.Crossbar" as CFString, callback, &context
        ) else {
            return nil
        }

        // Exact keys: the global primary-service pointers (default route owner).
        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
        ] as CFArray

        // Patterns: per-service IP, per-interface link, and the Setup domain
        // mirror of preferences (this is what changes when a service is
        // enabled/disabled or renamed in System Settings).
        let patterns = [
            "State:/Network/Service/[^/]+/IPv4",
            "State:/Network/Interface/[^/]+/Link",
            "Setup:/Network/Service/[^/]+",
            "Setup:/Network/Global/IPv4",
        ] as CFArray

        SCDynamicStoreSetNotificationKeys(store, keys, patterns)

        if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }

        return store
    }

    /// Coalesce bursts of change notifications into a single refresh. macOS
    /// often fires several key changes for one logical event (e.g. plugging in
    /// Ethernet touches Link, the service IPv4, and the global primary).
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    // MARK: - Enumeration

    /// Re-read and publish. Runs on the main thread, where the SCDynamicStore
    /// notifications arrive, so all SC reads stay serialized.
    private func refresh() {
        services = Self.readServices(store: store) { [wifiProvider] bsd in wifiProvider.ssid(forBSD: bsd) }
    }

    /// Build the model from SCPreferences (identity, enabled flag, service order)
    /// and SCDynamicStore (addresses, link, the primary service). Static so
    /// Shortcuts and the debug flags can read services without a live monitor.
    ///
    /// - Parameters:
    ///   - store: a dynamic store to read from; a temporary one is made if nil.
    ///   - ssid: looks up the Wi-Fi network name for a BSD interface.
    static func readServices(store: SCDynamicStore? = nil,
                             ssid: (String) -> String? = { _ in nil }) -> [NetworkServiceState] {
        // A fresh SCPreferences snapshot reflects the latest on-disk config, so
        // enable/disable changes made in System Settings show up here.
        guard let prefs = SCPreferencesCreate(nil, "com.breed.Crossbar" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let rawServices = SCNetworkSetCopyServices(set) as? [SCNetworkService]
        else { return [] }
        let store = store ?? SCDynamicStoreCreate(nil, "com.breed.Crossbar.read" as CFString, nil, nil)
        let reader = DynamicState(store: store)

        let order = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
        let primaryID = reader.primaryServiceID()

        var result: [NetworkServiceState] = []
        for service in rawServices where !HiddenInterfaces.isHidden(service) {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let name = SCNetworkServiceGetName(service) as String?
            else { continue }

            let interface = SCNetworkServiceGetInterface(service)
            let bsd = interface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
            let interfaceType = interface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
            let kind = Self.kind(forInterfaceType: interfaceType)
            let enabled = SCNetworkServiceGetEnabled(service)
            let (address, router) = reader.ipv4Info(serviceID: id)

            result.append(NetworkServiceState(
                id: id,
                name: name,
                bsdName: bsd,
                isEnabled: enabled,
                ipv4Address: address,
                router: router,
                hasActiveLink: bsd.map { reader.linkActive(bsd: $0) } ?? false,
                isPrimary: id == primaryID,
                kind: kind,
                ssid: (kind == .wifi && enabled) ? bsd.flatMap(ssid) : nil,
                orderIndex: order.firstIndex(of: id) ?? Int.max
            ))
        }

        // Prioritize by category (wired → Wi-Fi → VPN → bridges → other), then
        // by the configured service order within a category, then by name.
        result.sort { a, b in
            if a.kind.sortRank != b.kind.sortRank { return a.kind.sortRank < b.kind.sortRank }
            return a.orderIndex != b.orderIndex ? a.orderIndex < b.orderIndex : a.name < b.name
        }
        return result
    }

    /// Map an `SCNetworkInterfaceGetInterfaceType` value to a coarse category.
    private static func kind(forInterfaceType type: String?) -> NetworkServiceState.Kind {
        guard let type else { return .other }
        func eq(_ constant: CFString) -> Bool { type == (constant as String) }

        if eq(kSCNetworkInterfaceTypeEthernet) || eq(kSCNetworkInterfaceTypeFireWire) {
            return .wired
        }
        if eq(kSCNetworkInterfaceTypeIEEE80211) {
            return .wifi
        }
        // "VPN" and "Bridge" have no public kSCNetworkInterfaceType* constant
        // in the Swift overlay; their type strings are stable, so match literally.
        if type == "VPN" || eq(kSCNetworkInterfaceTypeIPSec)
            || eq(kSCNetworkInterfaceTypePPP) || eq(kSCNetworkInterfaceTypeL2TP) {
            return .vpn
        }
        if type == "Bridge" || eq(kSCNetworkInterfaceTypeBond)
            || eq(kSCNetworkInterfaceTypeVLAN) {
            return .aggregate
        }
        return .other
    }

}

/// Reads live state from the dynamic store. No privileges needed.
private struct DynamicState {
    let store: SCDynamicStore?

    private func value(_ key: String) -> [String: Any]? {
        guard let store else { return nil }
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    /// The service ID currently owning the default route — the one actually
    /// carrying traffic when several services are connected. Prefers the IPv4
    /// primary, falling back to IPv6 so the "active route" marker still appears
    /// on IPv6-only networks.
    func primaryServiceID() -> String? {
        (value("State:/Network/Global/IPv4")?["PrimaryService"]
         ?? value("State:/Network/Global/IPv6")?["PrimaryService"]) as? String
    }

    func ipv4Info(serviceID: String) -> (address: String?, router: String?) {
        guard let dict = value("State:/Network/Service/\(serviceID)/IPv4") else { return (nil, nil) }
        return ((dict["Addresses"] as? [String])?.first, dict["Router"] as? String)
    }

    func linkActive(bsd: String) -> Bool {
        (value("State:/Network/Interface/\(bsd)/Link")?["Active"] as? Bool) ?? false
    }
}
