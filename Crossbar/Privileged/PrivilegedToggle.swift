import Foundation

/// The privilege boundary, expressed as a protocol so the UI never knows how
/// root is actually reached. The v1 backend (`NetworksetupToggle`) shells out
/// to `networksetup` via a passwordless `sudo` rule; a future backend could be
/// an `SMAppService` daemon reached over XPC — swappable without touching the UI.
protocol PrivilegedToggle {
    /// Enable or disable a network service.
    ///
    /// - Important: `serviceName` MUST be a name that came from the live
    ///   enumerated service set (`SCNetworkServiceGetName`). Never pass a
    ///   user-typed or otherwise unvalidated string into this privileged path.
    func setEnabled(_ enabled: Bool, serviceName: String) async throws
}

/// Failures surfaced from the privileged path, with user-facing descriptions.
enum PrivilegedToggleError: LocalizedError {
    /// `sudo -n` reported a password would be required — almost always means the
    /// passwordless sudoers rule hasn't been installed yet.
    case sudoRuleMissing
    /// networksetup ran but exited non-zero.
    case commandFailed(status: Int32, message: String)
    /// The process couldn't be launched at all.
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .sudoRuleMissing:
            return "Crossbar can’t change network services yet because the passwordless sudo rule isn’t installed."
        case .commandFailed(let status, let message):
            let detail = message.isEmpty ? "" : "\n\n\(message)"
            return "networksetup failed (exit code \(status)).\(detail)"
        case .launchFailed(let message):
            return "Couldn’t run networksetup: \(message)"
        }
    }
}
