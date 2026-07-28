import Foundation

/// Constants shared by the app (client) and the CrossbarHelper daemon (server).
/// Compiled into BOTH targets — the XPC service name and the code-signing
/// requirements must be identical on both ends or the connection can't form.
enum HelperConstants {
    /// The privileged helper's Mach service name (matches its launchd plist).
    static let machServiceName = "com.breed.Crossbar.helper"

    /// The helper's bundle identifier (its `CFBundleIdentifier` / SMAppService plist name stem).
    static let helperBundleID = "com.breed.Crossbar.helper"

    /// Developer ID Team used to pin both ends.
    static let teamID = "YA83Q8FTH3"

    /// Requirement the HELPER enforces on connecting clients: must be the
    /// Crossbar app, signed by our team. Proven in the XPC spike.
    static let clientRequirement =
        "identifier \"com.breed.Crossbar\" and anchor apple generic and " +
        "certificate leaf[subject.OU] = \"\(teamID)\""

    /// Requirement the CLIENT enforces on the helper: must be our helper,
    /// signed by our team. Defense in depth (SMAppService already guarantees
    /// provenance, but pinning costs nothing).
    static let helperRequirement =
        "identifier \"\(helperBundleID)\" and anchor apple generic and " +
        "certificate leaf[subject.OU] = \"\(teamID)\""

    // MARK: - XPC message keys (the tiny request/reply contract)

    /// Request keys.
    enum Key {
        static let op = "op"                 // string
        static let serviceID = "serviceID"   // string — the authoritative target
        static let enabled = "enabled"       // bool
        // Reply keys.
        static let ok = "ok"                 // bool
        static let error = "error"           // string (optional)
    }

    /// The only operation in v1.
    static let opSetEnabled = "setEnabled"
}
