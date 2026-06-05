import AppKit

// Menu bar app entry point. LSUIElement in Info.plist hides the Dock icon;
// .accessory reinforces it at runtime.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
