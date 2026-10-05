import Foundation
import UserNotifications

/// Notifications for automated changes (F8). Permission is requested the first time
/// one happens; if it's denied, the menu bar flash is the only signal.
enum ToggleNotifier {
    static func post(_ announcement: AutomationToggle.Announcement) async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert])
        }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let content = UNMutableNotificationContent()
        (content.title, content.body) = text(for: announcement)
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Title and body for each announcement. Pure, so it's tested.
    static func text(for announcement: AutomationToggle.Announcement) -> (String, String) {
        switch announcement {
        case .changed(let applied, let source, let consequence):
            let who = source == .focus ? "Your Focus" : "A shortcut"
            let title: String
            var body: String
            if applied.count == 1, let only = applied.first {
                title = "Turned \(only.enabled ? "on" : "off") \(only.name)"
                body = "\(who) changed it."
            } else {
                title = "Changed \(applied.count) network services"
                let list = applied.map { "turned \($0.enabled ? "on" : "off") \($0.name)" }.joined(separator: ", ")
                body = "\(who) \(list)."
            }
            if let consequence { body += " \(consequence)" }
            return (title, body)
        case .setupNeeded:
            return ("Focus didn’t change network services",
                    "To let a Focus turn services on and off, choose Set Up Passwordless Toggling… in Crossbar.")
        case .failed(let names):
            return ("Couldn’t change \(names.joined(separator: ", "))",
                    "Your Focus tried to change network services. You can change them from Crossbar instead.")
        }
    }
}
