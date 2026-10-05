import AppIntents
import os

/// Every automation run is logged (service IDs only), so what macOS delivers, such
/// as a Focus filter's call when the Focus ends, can be checked afterward with
/// `/usr/bin/log show --predicate 'subsystem == "com.breed.Crossbar" AND category == "automation"'`.
private let automationLog = Logger(subsystem: HelperConstants.appBundleID, category: "automation")

// Shortcuts, Spotlight, Siri, and Focus integration (F8). These live in the app
// target, not an extension, so the helper's caller check (one signing identifier)
// covers them. The rules are in AutomationToggle; this file is the App Intents
// shell, and it's kept out of the test bundle.

/// A network service as Shortcuts, Spotlight, and Focus see it. Its properties are
/// read fresh, so Shortcuts conditions can test them.
struct NetworkServiceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Network Service"
    static let defaultQuery = NetworkServiceQuery()

    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Is On") var isOn: Bool
    @Property(title: "Is Connected") var isConnected: Bool
    @Property(title: "Carries Traffic") var carriesTraffic: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ service: NetworkServiceState) {
        id = service.id
        name = service.name
        isOn = service.isEnabled
        isConnected = service.connectivity == .connected
        carriesTraffic = service.isPrimary
    }
}

struct NetworkServiceQuery: EntityStringQuery {
    private func all() -> [NetworkServiceEntity] {
        StatusMonitor.readServices().map(NetworkServiceEntity.init)
    }

    func entities(for identifiers: [String]) async throws -> [NetworkServiceEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [NetworkServiceEntity] {
        let query = string.trimmingCharacters(in: .whitespaces)
        return all().filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    func suggestedEntities() async throws -> [NetworkServiceEntity] {
        all()
    }
}

enum ServiceSwitch: String, AppEnum {
    case on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "On or Off"
    static let caseDisplayRepresentations: [ServiceSwitch: DisplayRepresentation] = [
        .on: "On",
        .off: "Off",
    ]
}

/// "Set Network Service": turn a service on or off.
struct SetNetworkServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Network Service"
    static let description: IntentDescription? = IntentDescription("Turns a network service on or off.")
    static let openAppWhenRun = false

    @Parameter(title: "Service")
    var service: NetworkServiceEntity

    @Parameter(title: "State", default: .off)
    var state: ServiceSwitch

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$service) \(\.$state)")
    }

    init() {}

    init(state: ServiceSwitch) {
        self.state = state
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let on = state == .on
        let applied = try await AutomationToggle.live.run([.init(serviceID: service.id, enabled: on)], source: .shortcut)
        automationLog.notice("shortcut set \(service.id, privacy: .public) \(on ? "on" : "off", privacy: .public): \(applied.isEmpty ? "already" : "changed", privacy: .public)")
        let dialog = applied.isEmpty
            ? "\(service.name) is already \(on ? "on" : "off")."
            : "Turned \(on ? "on" : "off") \(service.name)."
        return .result(dialog: "\(dialog)")
    }
}

/// "Get Network Service": the service's current state, for Shortcuts conditions.
struct GetNetworkServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Network Service"
    static let description: IntentDescription? = IntentDescription(
        "Returns a network service with whether it’s on, connected, and carrying traffic.")
    static let openAppWhenRun = false

    @Parameter(title: "Service")
    var service: NetworkServiceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$service)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<NetworkServiceEntity> & ProvidesDialog {
        guard let current = StatusMonitor.readServices().first(where: { $0.id == service.id }) else {
            throw AutomationToggle.Failure.unknownService
        }
        let entity = NetworkServiceEntity(current)
        let state = !entity.isOn ? "off" : entity.carriesTraffic ? "on and carrying traffic"
            : entity.isConnected ? "on and connected" : "on but not connected"
        return .result(value: entity, dialog: "\(entity.name) is \(state).")
    }
}

/// A Focus filter: choose services to turn on and off when this Focus starts.
/// Ending the Focus changes nothing.
struct CrossbarFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Turn Network Services On or Off"
    static let description: IntentDescription? = IntentDescription(
        "Turns network services on or off when this Focus starts. Turning the Focus off doesn’t change them back.")

    /// Optional and empty by default, so whatever the system sends when a Focus ends
    /// (or a filter with nothing chosen) changes nothing.
    @Parameter(title: "Turn On")
    var turnOn: [NetworkServiceEntity]?

    @Parameter(title: "Turn Off")
    var turnOff: [NetworkServiceEntity]?

    var displayRepresentation: DisplayRepresentation {
        let on = (turnOn ?? []).map(\.name), off = (turnOff ?? []).map(\.name)
        var parts: [String] = []
        if !on.isEmpty { parts.append("Turn on \(on.joined(separator: ", "))") }
        if !off.isEmpty { parts.append("Turn off \(off.joined(separator: ", "))") }
        return DisplayRepresentation(title: "\(parts.isEmpty ? "Don’t change anything" : parts.joined(separator: "; "))")
    }

    func perform() async throws -> some IntentResult {
        let changes = (turnOn ?? []).map { AutomationToggle.Change(serviceID: $0.id, enabled: true) }
            + (turnOff ?? []).map { AutomationToggle.Change(serviceID: $0.id, enabled: false) }
        guard !changes.isEmpty else {
            automationLog.notice("focus filter ran with nothing chosen (Focus ended, or none set): no change")
            return .result()
        }
        // A Focus never throws to the user: AutomationToggle announces failures.
        let applied = (try? await AutomationToggle.live.run(changes, source: .focus)) ?? []
        automationLog.notice("focus filter asked for \(changes.count, privacy: .public) changes, applied \(applied.count, privacy: .public)")
        return .result()
    }
}

/// Spotlight and Siri phrases. Global keyboard shortcuts come from Shortcuts itself,
/// which can assign a key combination to a Set Network Service shortcut.
struct CrossbarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetNetworkServiceIntent(state: .off), phrases: [
            "Turn off \(\.$service) with \(.applicationName)",
            "Disable \(\.$service) with \(.applicationName)",
        ], shortTitle: "Turn Off Service", systemImageName: "network.slash")
        AppShortcut(intent: SetNetworkServiceIntent(state: .on), phrases: [
            "Turn on \(\.$service) with \(.applicationName)",
            "Enable \(\.$service) with \(.applicationName)",
        ], shortTitle: "Turn On Service", systemImageName: "network")
    }
}
