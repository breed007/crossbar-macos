import Foundation

/// What turning a service off will do to your traffic (F3). Pure, so it's tested
/// directly.
///
/// macOS sends traffic through the first service in the service order that has a
/// default route, which in practice means a router. So when the service carrying
/// traffic goes away, the next enabled service with a router, in service order,
/// takes over. If there isn't one, you're offline.
///
/// A VPN rides on another service. When a full-tunnel VPN is the primary service, the
/// link underneath it (the first enabled non-VPN service with a router) carries
/// traffic too: turning it off drops the VPN. And a VPN can never take over on its
/// own, so it's never a successor.
enum RoutePrediction: Equatable {
    /// The service isn't carrying traffic, so turning it off changes nothing you'd
    /// notice. Crossbar doesn't ask.
    case notActiveRoute
    /// Another service will carry traffic.
    case handoff(to: NetworkServiceState)
    /// Nothing else can carry traffic.
    case offline

    static func disabling(_ serviceID: String, in services: [NetworkServiceState]) -> RoutePrediction {
        guard let target = services.first(where: { $0.id == serviceID }), target.isEnabled,
              carriesTraffic(target, in: services)
        else { return .notActiveRoute }
        let successor = links(in: services).first { $0.id != serviceID }
        return successor.map { .handoff(to: $0) } ?? .offline
    }

    /// The same, for one of several services being turned off together: the others
    /// count as already off, so turning off Ethernet and Wi-Fi together predicts
    /// "offline", not a move to Wi-Fi.
    static func disabling(_ serviceID: String, in services: [NetworkServiceState],
                          alongWith others: [String]) -> RoutePrediction {
        let goingOff = Set(others).subtracting([serviceID])
        return disabling(serviceID, in: services.map { goingOff.contains($0.id) ? $0.turnedOff : $0 })
    }

    /// The primary service, or the link a primary VPN runs over.
    private static func carriesTraffic(_ service: NetworkServiceState, in services: [NetworkServiceState]) -> Bool {
        if service.isPrimary { return true }
        guard services.contains(where: { $0.isPrimary && $0.kind == .vpn }) else { return false }
        return links(in: services).first?.id == service.id
    }

    /// Enabled non-VPN services with a router, in service order: the ones that can
    /// carry traffic by themselves.
    private static func links(in services: [NetworkServiceState]) -> [NetworkServiceState] {
        services
            .filter { $0.kind != .vpn && $0.isEnabled && $0.router != nil }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    /// One plain sentence, for the confirmation and for automation notifications.
    var sentence: String? {
        switch self {
        case .notActiveRoute: return nil
        case .handoff(let next): return "Traffic will move to \(next.spokenName)."
        case .offline: return "Nothing else is connected, so you’ll go offline."
        }
    }
}
