import Foundation

/// Which services were just turned on and are still coming up (F4).
///
/// Right after a service is enabled, DHCP hasn't answered yet, so the row would
/// show a yellow "not connected" dot and a successful toggle would look like a
/// failure. While a service is settling its row says "Connecting…" instead, until
/// it connects, is turned off, disappears, or `window` seconds pass.
struct SettlingTracker {
    static let window: TimeInterval = 20

    private(set) var started: [String: Date] = [:]

    mutating func begin(_ serviceID: String, at date: Date = Date()) {
        started[serviceID] = date
    }

    /// Drop services that are done settling, one way or another.
    mutating func prune(_ services: [NetworkServiceState], now: Date = Date()) {
        let byID = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        started = started.filter { id, start in
            guard let service = byID[id], service.isEnabled else { return false }
            return service.connectivity != .connected && now.timeIntervalSince(start) < Self.window
        }
    }

    func isSettling(_ serviceID: String) -> Bool { started[serviceID] != nil }
}
