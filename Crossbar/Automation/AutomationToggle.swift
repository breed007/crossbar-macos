import Foundation

/// What happens when Shortcuts or a Focus asks Crossbar to turn services on or off
/// (F8). Free of App Intents, so the rules are unit-tested with fakes:
///
/// - A service already in the requested state is left alone and not announced.
/// - Turn-ons run before turn-offs. If a turn-off would take away the service
///   carrying traffic, Crossbar first waits (up to `routeWait`) for the services it
///   just turned on to get a router, so a Focus that swaps Ethernet for Wi-Fi doesn't
///   pass through a moment with nothing connected.
/// - Everything goes through `ToggleRouter`, whose backends never prompt, so it's
///   safe with nobody watching. There's no F3 confirmation: the user set up the rule.
/// - A shortcut throws on failure (Shortcuts shows the error). A Focus can't show an
///   error, so it announces what went wrong instead.
/// - Every change is announced, with the F3 prediction when the active route was
///   turned off, including changes made before a later one failed. That keeps
///   DESIGN.md's "no surprise network changes" promise.
struct AutomationToggle {
    enum Source: Equatable { case shortcut, focus }

    struct Change: Equatable {
        let serviceID: String
        let enabled: Bool
        /// The name the rule was set up with, for reporting a service that's gone.
        let name: String?

        init(serviceID: String, enabled: Bool, name: String? = nil) {
            self.serviceID = serviceID
            self.enabled = enabled
            self.name = name
        }
    }

    struct Applied: Equatable {
        let name: String
        let enabled: Bool
    }

    enum Announcement: Equatable {
        /// What changed, who changed it, and the route consequence if any.
        case changed([Applied], source: Source, consequence: String?)
        /// Neither the helper nor the sudo rule is set up.
        case setupNeeded
        /// A Focus couldn't change these services.
        case failed(names: [String])
    }

    enum Failure: LocalizedError, Equatable {
        case unknownService

        var errorDescription: String? { "That network service no longer exists." }
    }

    var services: () -> [NetworkServiceState]
    /// `ToggleRouter.shared.setEnabled(_:serviceID:serviceName:)` in the app.
    var setEnabled: (Bool, String, String) async throws -> Void
    var announce: (Announcement) async -> Void
    /// Pauses between checks while waiting for a turned-on service to connect.
    var pause: () async -> Void = { try? await Task.sleep(for: AutomationToggle.routePollInterval) }

    /// How long to wait for a just-enabled service to get a router before turning
    /// off the service carrying traffic. DHCP usually answers in a few seconds.
    static let routeWait: Duration = .seconds(15)
    static let routePollInterval: Duration = .milliseconds(500)

    /// Apply `changes` and return what actually changed.
    @discardableResult
    func run(_ changes: [Change], source: Source) async throws -> [Applied] {
        var applied: [Applied] = []
        var failed: [String] = []
        var consequence: String?
        var turnedOn: [String] = []

        // Say what changed whichever way this ends, including when a shortcut throws
        // partway through or a Focus finds no way to make changes.
        func report() async {
            if !applied.isEmpty { await announce(.changed(applied, source: source, consequence: consequence)) }
            if !failed.isEmpty { await announce(.failed(names: failed)) }
        }

        // Turn-ons first, keeping the requested order within each group.
        let turnOns = changes.filter(\.enabled), turnOffs = changes.filter { !$0.enabled }
        do {
            for (index, change) in (turnOns + turnOffs).enumerated() {
                if index == turnOns.count, !turnedOn.isEmpty {
                    await waitForRoutes(of: turnedOn, before: turnOffs)
                }
                let current = services()
                guard let service = current.first(where: { $0.id == change.serviceID }) else {
                    if source == .shortcut { throw Failure.unknownService }
                    failed.append(change.name ?? "a service that no longer exists")
                    continue
                }
                guard service.isEnabled != change.enabled else { continue }
                let prediction = change.enabled ? nil : RoutePrediction.disabling(service.id, in: current).sentence

                do {
                    try await setEnabled(change.enabled, service.id, service.name)
                    applied.append(Applied(name: service.name, enabled: change.enabled))
                    if change.enabled { turnedOn.append(service.id) }
                    consequence = consequence ?? prediction
                } catch PrivilegedToggleError.sudoRuleMissing where source == .focus {
                    await report()
                    await announce(.setupNeeded)
                    return applied
                } catch {
                    if source == .shortcut { throw error }
                    failed.append(service.name)
                }
            }
        } catch {
            await report()
            throw error
        }

        await report()
        return applied
    }

    /// Before a turn-off that would take away the service carrying traffic, give the
    /// services just turned on time to get a router, so traffic has somewhere to go.
    /// Returns early once they're all connected; gives up after `routeWait`.
    private func waitForRoutes(of turnedOn: [String], before turnOffs: [Change]) async {
        func needsWait() -> Bool {
            let current = services()
            let takesActiveRoute = turnOffs.contains {
                RoutePrediction.disabling($0.serviceID, in: current) != .notActiveRoute
            }
            let allConnected = turnedOn.allSatisfy { id in current.first { $0.id == id }?.router != nil }
            return takesActiveRoute && !allConnected
        }
        let polls = Int(Self.routeWait / Self.routePollInterval)
        for _ in 0..<polls {
            guard needsWait() else { return }
            await pause()
        }
    }

    /// The real backends.
    static let live = AutomationToggle(
        services: { StatusMonitor.readServices() },
        setEnabled: { try await ToggleRouter.shared.setEnabled($0, serviceID: $1, serviceName: $2) },
        announce: { announcement in
            if case .changed(let applied, _, _) = announcement {
                // Flash the change in the menu bar too (F5).
                await MainActor.run {
                    for change in applied {
                        NotificationCenter.default.post(name: .crossbarServiceToggled, object: nil,
                                                        userInfo: ["name": change.name, "enabled": change.enabled])
                    }
                }
            }
            await ToggleNotifier.post(announcement)
        })
}
