import Cocoa

// Programmatic entry point — no storyboard, no @NSApplicationMain.
// `.accessory` activation policy keeps Crossbar out of the Dock and the
// app switcher; it complements LSUIElement = YES from the generated Info.plist.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
