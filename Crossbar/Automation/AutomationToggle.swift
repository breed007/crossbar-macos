import Foundation

/// What happens when Shortcuts or a Focus asks Crossbar to turn services on or off
/// (F8). Free of App Intents, so the rules are unit-tested with fakes:
///
/// - A service already in the requested state is left alone and not announced.
/// - Turn-ons run before turn-offs, so a Focus that swaps Ethernet for Wi-Fi never
///   passes through a moment with nothing connected.
/// - Everything goes through `ToggleRouter`, whose backends never prompt, so it's
///   safe with nobody watching. There's no F3 confirmation: the user set up the rule.
/// - A shortcut throws on failure (Shortcuts shows the error). A Focus can't show an
///   error, so it announces what went wrong instead.
/// - Every change is announced, with the F3 prediction when the active route was
///   turned off. That keeps DESIGN.md's "no surprise network changes" promise.
struct AutomationToggle {
    enum Source: Equatable { case shortcut, focus }

    struct Change: Equatable {
        let serviceID: String
        let enabled: Bool
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

    /// Apply `changes` and return what actually changed.
    @discardableResult
    func run(_ changes: [Change], source: Source) async throws -> [Applied] {
        var applied: [Applied] = []
        var failed: [String] = []
        var consequence: String?

        // Turn-ons first, keeping the requested order within each group.
        let ordered = changes.filter(\.enabled) + changes.filter { !$0.enabled }
        for change in ordered {
            let current = services()
            guard let service = current.first(where: { $0.id == change.serviceID }) else {
                if source == .shortcut { throw Failure.unknownService }
                continue
            }
            guard service.isEnabled != change.enabled else { continue }
            let prediction = change.enabled ? nil : RoutePrediction.disabling(service.id, in: current).sentence

            do {
                try await setEnabled(change.enabled, service.id, service.name)
                applied.append(Applied(name: service.name, enabled: change.enabled))
                consequence = consequence ?? prediction
            } catch PrivilegedToggleError.sudoRuleMissing where source == .focus {
                await announce(.setupNeeded)
                return applied
            } catch {
                if source == .shortcut { throw error }
                failed.append(service.name)
            }
        }

        if !applied.isEmpty { await announce(.changed(applied, source: source, consequence: consequence)) }
        if !failed.isEmpty { await announce(.failed(names: failed)) }
        return applied
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
