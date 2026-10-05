import Foundation
import SystemConfiguration
import XPC
import os

// CrossbarHelper: the privileged (root) daemon. Its whole job is to enable or
// disable one existing network service, by stable service ID, for the signed
// Crossbar app. It has no other operation and must never gain one.
//
// Security model (validated in the v0.5 XPC spikes):
//   1. Every peer is pinned to `HelperConstants.clientRequirement`; the OS drops
//      messages from anything that isn't Crossbar signed by our team.
//   2. The client's service ID is checked for shape, then re-validated against
//      the live SCNetworkSet before any write. Names never cross the boundary.

private let log = Logger(subsystem: HelperConstants.helperBundleID, category: "toggle")

/// All work runs on one serial queue, so two callers can't race a commit.
private let workQueue = DispatchQueue(label: "com.breed.Crossbar.helper.work")

/// launchd starts the helper on demand; exit after a quiet minute instead of
/// holding a root process open. The next message relaunches it.
private var idleExit: DispatchWorkItem?
private func scheduleIdleExit() {
    idleExit?.cancel()
    let item = DispatchWorkItem { exit(0) }
    idleExit = item
    workQueue.asyncAfter(deadline: .now() + 60, execute: item)
}

/// Perform the privileged write. Returns nil on success, or an error code.
private func setEnabled(serviceID: String, enabled: Bool) -> String? {
    guard let prefs = SCPreferencesCreate(nil, HelperConstants.helperBundleID as CFString, nil),
          let set = SCNetworkSetCopyCurrent(prefs),
          let services = SCNetworkSetCopyServices(set) as? [SCNetworkService]
    else { return HelperConstants.ErrorCode.openPrefsFailed }

    // Validate the ID against live config. Never trust the client's word.
    guard let service = services.first(where: {
        (SCNetworkServiceGetServiceID($0) as String?) == serviceID
    }) else { return HelperConstants.ErrorCode.unknownServiceID }

    guard SCNetworkServiceSetEnabled(service, enabled) else { return HelperConstants.ErrorCode.setEnabledFailed }
    guard SCPreferencesCommitChanges(prefs) else { return HelperConstants.ErrorCode.commitFailed }
    guard SCPreferencesApplyChanges(prefs) else { return HelperConstants.ErrorCode.applyFailed }
    return nil
}

private func handle(_ message: xpc_object_t, from peer: xpc_connection_t) {
    guard let reply = xpc_dictionary_create_reply(message) else { return }
    let uid = xpc_connection_get_euid(peer)

    func send(_ error: String?) {
        xpc_dictionary_set_bool(reply, HelperConstants.Key.ok, error == nil)
        if let error { xpc_dictionary_set_string(reply, HelperConstants.Key.error, error) }
        xpc_connection_send_message(peer, reply)
    }

    guard let op = xpc_dictionary_get_string(message, HelperConstants.Key.op).map({ String(cString: $0) }),
          op == HelperConstants.opSetEnabled else {
        log.error("uid \(uid, privacy: .public): rejected unknown op")
        return send(HelperConstants.ErrorCode.unknownOp)
    }
    guard let serviceID = xpc_dictionary_get_string(message, HelperConstants.Key.serviceID).map({ String(cString: $0) }) else {
        log.error("uid \(uid, privacy: .public): request had no service ID")
        return send(HelperConstants.ErrorCode.missingServiceID)
    }
    guard HelperConstants.isWellFormedServiceID(serviceID) else {
        log.error("uid \(uid, privacy: .public): refused a malformed service ID")
        return send(HelperConstants.ErrorCode.unknownServiceID)
    }
    let enabled = xpc_dictionary_get_bool(message, HelperConstants.Key.enabled)

    // Service IDs are opaque GUIDs and logged in the clear; service names (which
    // can name a client's VPN) are never logged.
    let result = setEnabled(serviceID: serviceID, enabled: enabled)
    log.notice("uid \(uid, privacy: .public) set \(serviceID, privacy: .public) \(enabled ? "on" : "off", privacy: .public): \(result ?? "ok", privacy: .public)")
    send(result)
}

// MARK: - Listener

let listener = xpc_connection_create_mach_service(
    HelperConstants.machServiceName, workQueue,
    UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))

xpc_connection_set_event_handler(listener) { peer in
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }

    // Pin the caller. The OS enforces this per message; anything failing the
    // requirement never reaches `handle`.
    _ = xpc_connection_set_peer_code_signing_requirement(peer, HelperConstants.clientRequirement)
    xpc_connection_set_target_queue(peer, workQueue)

    xpc_connection_set_event_handler(peer) { event in
        guard xpc_get_type(event) != XPC_TYPE_ERROR else { return }
        handle(event, from: peer)
        scheduleIdleExit()
    }
    xpc_connection_resume(peer)
}
xpc_connection_resume(listener)
workQueue.async { scheduleIdleExit() }
dispatchMain()
