import Foundation
import ServiceManagement
@preconcurrency import XPC

/// What `ToggleRouter` needs from the privileged helper. A protocol so the router's
/// fallback rules can be tested with a fake.
protocol HelperBackend: AnyObject {
    /// Registered and approved, so it will accept calls.
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool, serviceID: String) async throws
}

/// The helper's registration state, as the Settings window shows it.
enum HelperStatus: Equatable {
    case enabled, requiresApproval, notRegistered, notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        default: self = .notFound
        }
    }

    var label: String {
        switch self {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        }
    }
}

/// Backend B: toggle a network service through the privileged CrossbarHelper daemon
/// over XPC. No sudoers rule, no subprocess. The helper does the `SCPreferences`
/// write as root. It's installed and approved through `SMAppService`.
final class HelperClient: HelperBackend {
    private var service: SMAppService { SMAppService.daemon(plistName: HelperConstants.plistName) }

    var status: HelperStatus { HelperStatus(service.status) }
    var isEnabled: Bool { service.status == .enabled }
    var requiresApproval: Bool { service.status == .requiresApproval }

    /// Register the helper. It usually lands in `.requiresApproval` until the user
    /// turns it on under Login Items & Extensions.
    ///
    /// On macOS 27, `register()` for a daemon throws "Operation not permitted" even
    /// though registration succeeded into `.requiresApproval` (found in Switchback's
    /// v0.5 milestone 1). That case is success: the user still has to approve it.
    func register() throws {
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                #if DEBUG
                FileHandle.standardError.write(Data("register() threw \"\(error.localizedDescription)\" but status is requires approval; treated as success\n".utf8))
                #endif
                return
            }
            throw error
        }
    }

    /// Remove the helper.
    func unregister() throws {
        guard service.status != .notRegistered else { return }
        try service.unregister()
    }

    /// Open System Settings → General → Login Items & Extensions, where the user
    /// approves the helper.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setEnabled(_ enabled: Bool, serviceID: String) async throws {
        guard isEnabled else { throw PrivilegedToggleError.helperNotInstalled }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let conn = xpc_connection_create_mach_service(HelperConstants.machServiceName, nil, 0)

            // Defense in depth: pin the helper's signature too.
            _ = xpc_connection_set_peer_code_signing_requirement(conn, HelperConstants.helperRequirement)

            xpc_connection_set_event_handler(conn) { _ in }   // required before resume
            xpc_connection_resume(conn)

            let msg = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(msg, HelperConstants.Key.op, HelperConstants.opSetEnabled)
            xpc_dictionary_set_string(msg, HelperConstants.Key.serviceID, serviceID)
            xpc_dictionary_set_bool(msg, HelperConstants.Key.enabled, enabled)

            xpc_connection_send_message_with_reply(conn, msg, DispatchQueue.global()) { reply in
                defer { xpc_connection_cancel(conn) }

                if xpc_get_type(reply) == XPC_TYPE_ERROR {
                    let description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                        .map { String(cString: $0) } ?? "connection error"
                    cont.resume(throwing: PrivilegedToggleError.helperCommunicationFailed(description))
                    return
                }
                if xpc_dictionary_get_bool(reply, HelperConstants.Key.ok) {
                    cont.resume()
                } else {
                    let code = xpc_dictionary_get_string(reply, HelperConstants.Key.error)
                        .map { String(cString: $0) } ?? "unknown"
                    cont.resume(throwing: PrivilegedToggleError.helperReportedError(code))
                }
            }
        }
    }
}
