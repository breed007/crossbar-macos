import Foundation
import SystemConfiguration
import XPC

// CrossbarHelper — the privileged (root) daemon. Its entire job: flip one
// network service's enabled flag, by stable service ID, after verifying the
// caller is the real Crossbar app. Minimal by design — one op, nothing else.
//
// Security model (see the XPC spike that validated this):
//   1. Every peer is pinned to `clientRequirement` — the OS drops messages from
//      anything that isn't the Crossbar app signed by our Team ID.
//   2. The client-supplied serviceID is re-validated against the live
//      SCNetworkSet before any write. A name is never accepted from the client.

/// Perform the privileged write. Returns nil on success, or an error string.
private func setEnabled(serviceID: String, enabled: Bool) -> String? {
    guard let prefs = SCPreferencesCreate(nil, "com.breed.Crossbar.helper" as CFString, nil),
          let set = SCNetworkSetCopyCurrent(prefs),
          let services = SCNetworkSetCopyServices(set) as? [SCNetworkService]
    else { return "open-prefs-failed" }

    // (2) Validate the ID against live config — never trust the client's word.
    guard let service = services.first(where: {
        (SCNetworkServiceGetServiceID($0) as String?) == serviceID
    }) else { return "unknown-service-id" }

    guard SCNetworkServiceSetEnabled(service, enabled) else { return "set-enabled-failed" }
    guard SCPreferencesCommitChanges(prefs) else { return "commit-failed" }
    guard SCPreferencesApplyChanges(prefs) else { return "apply-failed" }
    return nil
}

private func handle(_ message: xpc_object_t, from peer: xpc_connection_t) {
    let reply = xpc_dictionary_create_reply(message)!

    func fail(_ why: String) {
        xpc_dictionary_set_bool(reply, HelperConstants.Key.ok, false)
        xpc_dictionary_set_string(reply, HelperConstants.Key.error, why)
        xpc_connection_send_message(peer, reply)
    }

    guard let opC = xpc_dictionary_get_string(message, HelperConstants.Key.op),
          String(cString: opC) == HelperConstants.opSetEnabled else {
        return fail("unsupported-op")
    }
    guard let idC = xpc_dictionary_get_string(message, HelperConstants.Key.serviceID) else {
        return fail("missing-service-id")
    }
    let serviceID = String(cString: idC)
    let enabled = xpc_dictionary_get_bool(message, HelperConstants.Key.enabled)

    if let err = setEnabled(serviceID: serviceID, enabled: enabled) {
        return fail(err)
    }
    xpc_dictionary_set_bool(reply, HelperConstants.Key.ok, true)
    xpc_connection_send_message(peer, reply)
}

// MARK: - Listener

let listener = xpc_connection_create_mach_service(
    HelperConstants.machServiceName, nil,
    UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))

xpc_connection_set_event_handler(listener) { peer in
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }

    // (1) Pin the caller. The OS enforces this per-message; anything failing the
    // requirement never reaches our handler.
    _ = xpc_connection_set_peer_code_signing_requirement(
        peer, HelperConstants.clientRequirement)

    xpc_connection_set_event_handler(peer) { event in
        guard xpc_get_type(event) != XPC_TYPE_ERROR else { return }
        handle(event, from: peer)
    }
    xpc_connection_resume(peer)
}
xpc_connection_resume(listener)
dispatchMain()
