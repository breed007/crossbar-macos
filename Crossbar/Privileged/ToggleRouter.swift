import Foundation

/// Routes privileged toggles to the best available backend:
///   - **Backend B** (`SMAppServiceToggle`) when the helper daemon is installed
///     and enabled — no sudoers rule, unambiguous by service ID.
///   - **Backend A** (`NetworksetupToggle`) otherwise — the sudoers/`networksetup`
///     fallback, for when the helper isn't set up (or on managed Macs where it
///     can't be approved).
///
/// The UI holds only this (a `PrivilegedToggle`), so it never knows or cares
/// which backend actually ran — the seam the whole design rests on.
final class ToggleRouter: PrivilegedToggle {
    let helper: SMAppServiceToggle
    private let networksetup: NetworksetupToggle

    init(helper: SMAppServiceToggle = SMAppServiceToggle(),
         networksetup: NetworksetupToggle = NetworksetupToggle()) {
        self.helper = helper
        self.networksetup = networksetup
    }

    /// Which backend a toggle would use right now.
    var usingHelper: Bool { helper.isInstalled }

    func setEnabled(_ enabled: Bool, serviceID: String, serviceName: String) async throws {
        if helper.isInstalled {
            try await helper.setEnabled(enabled, serviceID: serviceID, serviceName: serviceName)
        } else {
            try await networksetup.setEnabled(enabled, serviceID: serviceID, serviceName: serviceName)
        }
    }
}
