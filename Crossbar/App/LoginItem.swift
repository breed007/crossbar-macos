import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` — registers Crossbar to launch at
/// login. This is deliberately the *first* use of SMAppService in the app: it
/// exercises the register/unregister/status surface on the low-risk login-item
/// path before the same framework is trusted with the privileged helper.
enum LoginItem {
    /// Whether Crossbar is currently set to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turn launch-at-login on or off. Throws if the system rejects the change
    /// (e.g. the user must approve it in Login Items & Extensions).
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    /// True when the change requires the user to approve Crossbar under
    /// System Settings → General → Login Items & Extensions.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
