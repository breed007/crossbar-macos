import Foundation
import ServiceManagement
import XPC

/// Backend B: toggle a network service via the privileged CrossbarHelper daemon
/// over XPC. No sudoers rule, no subprocess — the helper does the `SCPreferences`
/// write directly as root. The daemon is installed/approved via `SMAppService`.
final class SMAppServiceToggle: PrivilegedToggle {

    /// The registered helper daemon.
    private var service: SMAppService {
        SMAppService.daemon(plistName: "\(HelperConstants.helperBundleID).plist")
    }

    /// Whether the helper is registered and enabled (ready to receive calls).
    var isInstalled: Bool { service.status == .enabled }

    /// Whether the helper is registered but awaiting user approval in Settings.
    var requiresApproval: Bool { service.status == .requiresApproval }

    /// Register the helper daemon. May leave it in `.requiresApproval` until the
    /// user enables it under Login Items & Extensions.
    func install() throws {
        if service.status != .enabled {
            try service.register()
        }
    }

    /// Remove the helper daemon.
    func uninstall() throws {
        if service.status != .notRegistered {
            try service.unregister()
        }
    }

    func setEnabled(_ enabled: Bool, serviceID: String, serviceName: String) async throws {
        guard isInstalled else { throw PrivilegedToggleError.helperNotInstalled }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let conn = xpc_connection_create_mach_service(
                HelperConstants.machServiceName, nil, 0)

            // Defense in depth: pin the helper's signature too (SMAppService
            // already guarantees provenance, but this costs nothing).
            _ = xpc_connection_set_peer_code_signing_requirement(
                conn, HelperConstants.helperRequirement)

            xpc_connection_set_event_handler(conn) { _ in }   // required before resume
            xpc_connection_resume(conn)

            let msg = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(msg, HelperConstants.Key.op, HelperConstants.opSetEnabled)
            xpc_dictionary_set_string(msg, HelperConstants.Key.serviceID, serviceID)
            xpc_dictionary_set_bool(msg, HelperConstants.Key.enabled, enabled)

            xpc_connection_send_message_with_reply(msg, conn, DispatchQueue.global()) { reply in
                defer { xpc_connection_cancel(conn) }

                if xpc_get_type(reply) == XPC_TYPE_ERROR {
                    let d = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                        .map { String(cString: $0) } ?? "connection error"
                    cont.resume(throwing: PrivilegedToggleError.helperCommunicationFailed(d))
                    return
                }
                if xpc_dictionary_get_bool(reply, HelperConstants.Key.ok) {
                    cont.resume()
                } else {
                    let err = xpc_dictionary_get_string(reply, HelperConstants.Key.error)
                        .map { String(cString: $0) } ?? "unknown"
                    cont.resume(throwing: PrivilegedToggleError.helperReportedError(err))
                }
            }
        }
    }
}
