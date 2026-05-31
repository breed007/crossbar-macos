import Foundation

/// A snapshot of one network service's state.
///
/// Assembled from two sources:
///   - SCPreferences (via the current network set): identity + enabled flag.
///   - SCDynamicStore: live IPv4 address, router, link state, and which
///     service currently owns the default route (the "primary" service).
struct NetworkServiceState: Identifiable, Equatable {
    /// How the service presents in the list at a glance.
    enum Connectivity {
        case connected      // enabled, and has an IPv4 address or an active link
        case notConnected   // enabled, but no address and link is down
        case inactive       // service is disabled ("Make Service Inactive")
    }

    /// Coarse interface category, used to prioritize the list: real NICs you
    /// actually route over (wired, Wi-Fi) sort above auxiliary services
    /// (VPNs, bridges/bonds, everything else). The SC-type → Kind mapping
    /// lives in StatusMonitor so this model stays framework-light.
    enum Kind {
        case wired, wifi, vpn, aggregate, other

        /// Lower sorts first.
        var sortRank: Int {
            switch self {
            case .wired:     return 0
            case .wifi:      return 1
            case .vpn:       return 2
            case .aggregate: return 3
            case .other:     return 4
            }
        }
    }

    let id: String          // SCNetworkService service ID (stable across renames)
    let name: String        // user-visible name, e.g. "Wi-Fi"
    let bsdName: String?     // backing interface, e.g. "en0" (nil for some VPN/PPP)
    let isEnabled: Bool      // SCNetworkServiceGetEnabled
    let ipv4Address: String?
    let router: String?
    let hasActiveLink: Bool
    let isPrimary: Bool      // currently carrying the default route (active route)
    let kind: Kind           // interface category, drives list priority
    let ssid: String?        // connected Wi-Fi network name (Wi-Fi only)

    var connectivity: Connectivity {
        guard isEnabled else { return .inactive }
        if ipv4Address != nil || hasActiveLink { return .connected }
        return .notConnected
    }

    /// The three route states the UI distinguishes (per spec): a disabled
    /// service, the one enabled service actually carrying traffic, and an
    /// enabled service sitting behind a higher-priority one.
    var routeState: String {
        guard isEnabled else { return "Disabled" }
        return isPrimary ? "Enabled & routing" : "Enabled & dormant"
    }
}
