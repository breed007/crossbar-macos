import Cocoa

/// Whether to ask before turning a service off, and what to say (F3).
///
/// - A dormant service never asks: turning it off changes nothing you'd notice.
/// - Turning off the active route when another service can take over asks, unless
///   the user chose "Don't ask again" for that case.
/// - Going offline, or a change that may drop a remote session, always asks.
struct ToggleConfirmation: Equatable {
    let title: String
    let message: String
    /// Only the plain handoff case can be silenced.
    let offersDontAskAgain: Bool

    static func plan(serviceName: String, prediction: RoutePrediction,
                     remoteSessions: [RemoteSession], confirmHandoff: Bool) -> ToggleConfirmation? {
        guard let sentence = prediction.sentence else { return nil }   // not the active route
        let remote = RemoteSessions.warning(for: remoteSessions)
        if case .handoff = prediction, remote == nil, !confirmHandoff { return nil }

        var isHandoff = false
        if case .handoff = prediction { isHandoff = true }
        return ToggleConfirmation(
            title: "Turn off \(serviceName)?",
            message: [sentence, remote].compactMap { $0 }.joined(separator: " "),
            offersDontAskAgain: isHandoff && remote == nil)
    }

    /// Show the alert. Returns true if the user chose to turn the service off. A
    /// checked "Don't ask again" turns off `Preferences.confirmRouteHandoff`.
    @MainActor
    func confirm(_ preferences: Preferences = Preferences()) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let turnOff = alert.addButton(withTitle: "Turn Off")
        turnOff.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if offersDontAskAgain {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t ask when traffic can move to another service"
        }
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, offersDontAskAgain, alert.suppressionButton?.state == .on {
            preferences.confirmRouteHandoff = false
        }
        return confirmed
    }
}
