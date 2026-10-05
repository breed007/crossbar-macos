import Foundation

/// What turning a service off will do to your traffic (F3). Pure, so it's tested
/// directly.
///
/// macOS sends traffic through the first service in the service order that has a
/// default route, which in practice means a router. So when the service carrying
/// traffic goes away, the next enabled service with a router, in service order,
/// takes over. If there isn't one, you're offline.
enum RoutePrediction: Equatable {
    /// The service isn't carrying traffic, so turning it off changes nothing you'd
    /// notice. Crossbar doesn't ask.
    case notActiveRoute
    /// Another service will carry traffic.
    case handoff(to: NetworkServiceState)
    /// Nothing else can carry traffic.
    case offline

    static func disabling(_ serviceID: String, in services: [NetworkServiceState]) -> RoutePrediction {
        guard let target = services.first(where: { $0.id == serviceID }), target.isPrimary, target.isEnabled
        else { return .notActiveRoute }
        let successor = services
            .filter { $0.id != serviceID && $0.isEnabled && $0.router != nil }
            .min { $0.orderIndex < $1.orderIndex }
        return successor.map { .handoff(to: $0) } ?? .offline
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
