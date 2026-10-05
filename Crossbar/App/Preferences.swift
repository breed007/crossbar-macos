import Foundation

extension Notification.Name {
    /// A setting changed in the Settings window; the menu bar title refreshes.
    static let crossbarPreferencesChanged = Notification.Name("com.breed.Crossbar.preferencesChanged")
    /// A service was just turned on or off, from the popover or an automation.
    /// `userInfo`: `"name"` (String), `"enabled"` (Bool). The menu bar flashes it.
    static let crossbarServiceToggled = Notification.Name("com.breed.Crossbar.serviceToggled")
}

/// User settings, in `UserDefaults`. The defaults are injectable so tests use their
/// own suite.
struct Preferences {
    static let showNetworkNameKey = "ShowNetworkNameInMenuBar"
    static let confirmRouteHandoffKey = "ConfirmRouteHandoff"

    let defaults: UserDefaults

    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.showNetworkNameKey: false,
                                     Self.confirmRouteHandoffKey: true])
    }

    /// Keep the active network's name next to the menu bar icon (F5). Off by default.
    var showNetworkName: Bool {
        get { defaults.bool(forKey: Self.showNetworkNameKey) }
        nonmutating set { set(newValue, Self.showNetworkNameKey) }
    }

    /// Ask before turning off the active route when another service can take over
    /// (F3). On by default. Going offline or cutting a remote session always asks.
    var confirmRouteHandoff: Bool {
        get { defaults.bool(forKey: Self.confirmRouteHandoffKey) }
        nonmutating set { set(newValue, Self.confirmRouteHandoffKey) }
    }

    private func set(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .crossbarPreferencesChanged, object: nil)
    }
}
