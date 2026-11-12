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
    static let checkForUpdatesKey = "CheckForUpdates"
    static let lastUpdateCheckKey = "LastUpdateCheck"
    static let latestVersionKey = "LatestKnownVersion"
    static let latestURLKey = "LatestKnownReleaseURL"

    let defaults: UserDefaults

    init(_ defaults: UserDefaults = .standard) {
        #if DEBUG
        let defaults = DemoData.active ? DemoData.defaults : defaults
        #endif
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

    /// Check GitHub for a newer release once a day (v0.7 U1). Nil until the user
    /// answers the popover's one-time question; the check never runs while nil.
    var checkForUpdates: Bool? {
        get { defaults.object(forKey: Self.checkForUpdatesKey) as? Bool }
        nonmutating set { defaults.set(newValue, forKey: Self.checkForUpdatesKey) }
    }

    /// When the last update check was attempted, whether or not it got an answer.
    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Self.lastUpdateCheckKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastUpdateCheckKey) }
    }

    /// The newest release the last successful check found, so the popover line
    /// survives a relaunch.
    var latestKnownRelease: (version: String, url: String)? {
        get {
            guard let version = defaults.string(forKey: Self.latestVersionKey),
                  let url = defaults.string(forKey: Self.latestURLKey) else { return nil }
            return (version, url)
        }
        nonmutating set {
            defaults.set(newValue?.version, forKey: Self.latestVersionKey)
            defaults.set(newValue?.url, forKey: Self.latestURLKey)
        }
    }

    private func set(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .crossbarPreferencesChanged, object: nil)
    }
}
