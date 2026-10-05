import Foundation

/// Routes privileged toggles to the best available backend:
///   - **Backend B** (the helper) when it's installed and approved: no sudoers rule,
///     unambiguous by service ID.
///   - **Backend A** (`sudo -n networksetup`) otherwise, for when the helper isn't
///     set up, or on managed Macs where it can't be approved.
///
/// If the helper is approved but can't be reached (launchd didn't start it, or the
/// connection dropped), the router falls back to Backend A. It does *not* fall back
/// when the helper ran and reported a failure: that's a real answer, and retrying it
/// another way would hide it.
///
/// The UI, Shortcuts, and Focus all hold this one router, so the UI never knows or
/// cares which backend ran. Neither backend ever prompts, so automations can use it.
final class ToggleRouter: PrivilegedToggle {
    static let shared = ToggleRouter()

    private let helper: HelperBackend
    private let fallback: PrivilegedToggle

    init(helper: HelperBackend = HelperClient(), fallback: PrivilegedToggle = NetworksetupToggle()) {
        self.helper = helper
        self.fallback = fallback
    }

    /// Whether a toggle would go through the helper right now.
    var usingHelper: Bool { helper.isEnabled }

    func setEnabled(_ enabled: Bool, serviceID: String, serviceName: String) async throws {
        var helperError: Error?
        if helper.isEnabled {
            do {
                try await helper.setEnabled(enabled, serviceID: serviceID)
                return
            } catch PrivilegedToggleError.helperCommunicationFailed(let reason) {
                helperError = PrivilegedToggleError.helperCommunicationFailed(reason)
            } catch PrivilegedToggleError.helperNotInstalled {
                helperError = PrivilegedToggleError.helperNotInstalled
            }
            // Any other error (the helper reported a failure) propagates as is.
        }

        do {
            try await fallback.setEnabled(enabled, serviceID: serviceID, serviceName: serviceName)
        } catch PrivilegedToggleError.sudoRuleMissing where helperError != nil {
            // The user set up the helper, so "install the sudo rule" would be the
            // wrong advice. Report why the helper failed instead.
            throw helperError!
        }
    }
}
