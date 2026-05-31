import Cocoa

/// Top-level app lifecycle. Its only job at M0 is to stand up the menu bar
/// status item once the app has finished launching.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
    }
}
