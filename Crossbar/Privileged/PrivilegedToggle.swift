import Foundation

/// The privilege boundary, expressed as a protocol so the UI never knows how
/// root is actually reached. The v1 backend (`NetworksetupToggle`) shells out
/// to `networksetup` via a passwordless `sudo` rule; a future backend could be
/// an `SMAppService` daemon reached over XPC — swappable without touching the UI.
protocol PrivilegedToggle {
    /// Enable or disable a network service.
    ///
    /// Both identifiers come from the live enumerated set (`NetworkServiceState`):
    /// - `serviceID` is the stable `SCNetworkService` ID — the authoritative
    ///   target used by the XPC backend (unambiguous even with duplicate names).
    /// - `serviceName` is the display name — used by the `networksetup` backend,
    ///   which only accepts names. MUST be a name from `SCNetworkServiceGetName`;
    ///   never a user-typed or otherwise unvalidated string.
    func setEnabled(_ enabled: Bool, serviceID: String, serviceName: String) async throws
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
    /// The privileged helper isn't installed/approved yet.
    case helperNotInstalled
    /// The XPC call to the helper failed (connection or protocol error).
    case helperCommunicationFailed(String)
    /// The helper ran but reported a failure performing the change.
    case helperReportedError(String)

    var errorDescription: String? {
        switch self {
        case .sudoRuleMissing:
            return "Crossbar can’t change network services yet because the passwordless sudo rule isn’t installed."
        case .commandFailed(let status, let message):
            let detail = message.isEmpty ? "" : "\n\n\(message)"
            return "networksetup failed (exit code \(status)).\(detail)"
        case .launchFailed(let message):
            return "Couldn’t run networksetup: \(message)"
        case .helperNotInstalled:
            return "Crossbar’s privileged helper isn’t installed yet."
        case .helperCommunicationFailed(let message):
            return "Couldn’t reach Crossbar’s helper: \(message)"
        case .helperReportedError(let message):
            return "The helper couldn’t change the service: \(message)"
        }
    }
}
