import Cocoa

/// The "Set Up Passwordless Toggling…" flow, shared by the popover and the
/// Settings window.
///
/// Every way registration can stall ends in the same place: the user approves
/// Crossbar under System Settings → General → Login Items & Extensions. A first
/// registration lands in `.requiresApproval`. A registration attempted while an
/// earlier request is still pending (or after the user turned the item off) throws
/// "Operation not permitted" and stays unregistered until the user allows it there.
/// So a failure points at Login Items instead of ending in a dead-end error.
enum HelperSetup {
    enum Outcome { case enabled, awaitingApproval, failed }

    @discardableResult
    static func run(_ helper: HelperClient = HelperClient()) -> Outcome {
        NSApp.activate(ignoringOtherApps: true)
        do {
            try helper.register()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Allow Crossbar in Login Items"
            alert.informativeText = "macOS didn’t register Crossbar’s helper (\(error.localizedDescription)). "
                + "This usually means an earlier request is waiting for approval. Turn on Crossbar under "
                + "Login Items & Extensions, then choose Set Up Passwordless Toggling… again."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { HelperClient.openLoginItemsSettings() }
            return .failed
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        if helper.requiresApproval {
            alert.messageText = "One more step"
            alert.informativeText = "Turn on Crossbar under System Settings → General → Login Items & "
                + "Extensions to finish setting up passwordless toggling. macOS asks for an "
                + "administrator password once."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { HelperClient.openLoginItemsSettings() }
            return .awaitingApproval
        }
        alert.messageText = "Passwordless toggling is set up"
        alert.informativeText = "Crossbar can now turn network services on and off without the sudo rule."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return .enabled
    }
}
