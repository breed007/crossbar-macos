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
enum PrivilegedToggleError: LocalizedError, Equatable {
    /// `sudo -n` reported a password would be required: the helper isn't set up
    /// and the passwordless sudoers rule isn't installed either.
    case sudoRuleMissing
    /// networksetup ran but exited non-zero.
    case commandFailed(status: Int32, message: String)
    /// The process couldn't be launched at all.
    case launchFailed(String)
    /// networksetup didn't finish within the timeout and was terminated.
    case timedOut
    /// The privileged helper isn't installed and approved.
    case helperNotInstalled
    /// The XPC call to the helper failed (it couldn't be reached).
    case helperCommunicationFailed(String)
    /// The helper ran but reported a failure, as a `HelperConstants.ErrorCode`.
    case helperReportedError(String)

    var errorDescription: String? {
        switch self {
        case .sudoRuleMissing:
            return "Crossbar can’t change network services yet. Choose Set Up Passwordless Toggling… in Crossbar, or install the sudo rule described in the README."
        case .commandFailed(let status, let message):
            let detail = message.isEmpty ? "" : "\n\n\(message)"
            return "networksetup failed (exit code \(status)).\(detail)"
        case .launchFailed(let message):
            return "Couldn’t run networksetup: \(message)"
        case .timedOut:
            return "networksetup didn’t respond, so Crossbar stopped it. Try again in a moment."
        case .helperNotInstalled:
            return "Crossbar’s helper isn’t set up yet."
        case .helperCommunicationFailed(let message):
            return "Couldn’t reach Crossbar’s helper: \(message)"
        case .helperReportedError(let code):
            return "The helper couldn’t change the service (\(Self.describe(code)))."
        }
    }

    /// Plain words for the helper's error codes.
    static func describe(_ code: String) -> String {
        switch code {
        case HelperConstants.ErrorCode.unknownServiceID: return "that service no longer exists"
        case HelperConstants.ErrorCode.missingServiceID: return "no service was named"
        case HelperConstants.ErrorCode.unknownOp: return "the helper is older than this app; reinstall it from Settings"
        case HelperConstants.ErrorCode.commitFailed,
             HelperConstants.ErrorCode.applyFailed: return "macOS refused to save the change"
        case HelperConstants.ErrorCode.openPrefsFailed: return "couldn’t read the network configuration"
        default: return code
        }
    }
}
