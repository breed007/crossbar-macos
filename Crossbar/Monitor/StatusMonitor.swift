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
/// service, including phantom entries that System Settings hides (e.g. unused
/// Thunderbolt-slot "Ethernet Adapter (enN)" services). To match what the user
/// actually sees — and to guarantee every row is a name the M2 toggle command
/// accepts — we gate the list through `networksetup -listallnetworkservices`,
/// the same tool that defines the user-facing/togglable universe. SCDynamicStore
/// remains the live-state source and the change trigger; the only subprocess
/// runs on change events (never on a timer) and off the main thread.
final class StatusMonitor: ObservableObject {
    @Published private(set) var services: [NetworkServiceState] = []

    private var store: SCDynamicStore!
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

    /// Two-phase refresh: fetch the user-facing service names off the main
    /// thread (the only subprocess), then assemble the model from
    /// SCPreferences + SCDynamicStore back on main and publish.
    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let visibleNames = self?.userFacingServiceNames()
            DispatchQueue.main.async {
                self?.rebuildModel(visibleNames: visibleNames)
            }
        }
    }

    /// The set of service names System Settings considers user-facing, via
    /// `networksetup -listallnetworkservices`. Returns `nil` if the command
    /// can't be run, in which case we degrade to showing everything rather
    /// than an empty list.
    private func userFacingServiceNames() -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallnetworkservices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }

        // First line is the "An asterisk (*) denotes..." legend; a leading "*"
        // on a service line marks it disabled (state we read from SC anyway).
        var names = Set<String>()
        for line in output.split(separator: "\n").dropFirst() {
            var name = String(line)
            if name.hasPrefix("*") { name.removeFirst() }
            names.insert(name.trimmingCharacters(in: .whitespaces))
        }
        return names
    }

    /// Assemble and publish the model. Runs on the main thread (same thread the
    /// SCDynamicStore notifications arrive on), so all SC reads stay serialized.
    private func rebuildModel(visibleNames: Set<String>?) {
        // A fresh SCPreferences snapshot reflects the latest on-disk config,
        // so enable/disable changes made in System Settings show up here.
        guard let prefs = SCPreferencesCreate(nil, "com.breed.Crossbar" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let rawServices = SCNetworkSetCopyServices(set) as? [SCNetworkService]
        else {
            services = []
            return
        }

        let order = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
        let primaryID = primaryServiceID()

        var result: [NetworkServiceState] = []
        for service in rawServices {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                  let name = SCNetworkServiceGetName(service) as String?
            else { continue }

            // Hide services System Settings hides (phantom adapters), unless
            // networksetup was unavailable (visibleNames == nil → show all).
            if let visibleNames, !visibleNames.contains(name) { continue }

            let interface = SCNetworkServiceGetInterface(service)
            let bsd = interface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
            let interfaceType = interface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
            let kind = Self.kind(forInterfaceType: interfaceType)
            let enabled = SCNetworkServiceGetEnabled(service)
            let (address, router) = ipv4Info(serviceID: id)
            let linkActive = bsd.map { self.linkActive(bsd: $0) } ?? false
            let ssid = (kind == .wifi && enabled) ? bsd.flatMap { wifiProvider.ssid(forBSD: $0) } : nil

            result.append(NetworkServiceState(
                id: id,
                name: name,
                bsdName: bsd,
                isEnabled: enabled,
                ipv4Address: address,
                router: router,
                hasActiveLink: linkActive,
                isPrimary: id == primaryID,
                kind: kind,
                ssid: ssid
            ))
        }

        // Prioritize by category (wired → Wi-Fi → VPN → bridges → other), then
        // by the configured service order within a category, then by name.
        let orderIndex: (NetworkServiceState) -> Int = { order.firstIndex(of: $0.id) ?? Int.max }
        result.sort { a, b in
            if a.kind.sortRank != b.kind.sortRank { return a.kind.sortRank < b.kind.sortRank }
            let ia = orderIndex(a), ib = orderIndex(b)
            return ia != ib ? ia < ib : a.name < b.name
        }

        services = result
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

    // MARK: - SCDynamicStore reads

    /// The service ID currently owning the default IPv4 route — i.e. the one
    /// actually carrying traffic when several services are connected at once.
    private func primaryServiceID() -> String? {
        let key = "State:/Network/Global/IPv4" as CFString
        guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return nil }
        return dict["PrimaryService"] as? String
    }

    private func ipv4Info(serviceID: String) -> (address: String?, router: String?) {
        let key = "State:/Network/Service/\(serviceID)/IPv4" as CFString
        guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any] else {
            return (nil, nil)
        }
        let address = (dict["Addresses"] as? [String])?.first
        let router = dict["Router"] as? String
        return (address, router)
    }

    private func linkActive(bsd: String) -> Bool {
        let key = "State:/Network/Interface/\(bsd)/Link" as CFString
        guard let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return false }
        return (dict["Active"] as? Bool) ?? false
    }
}
