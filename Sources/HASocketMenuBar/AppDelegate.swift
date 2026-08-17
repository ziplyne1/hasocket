import AppKit

// Keeps the app out of the Dock/app switcher even when it isn't packaged
// as a proper .app bundle with LSUIElement set (e.g. `swift run` while
// developing). build-app.sh sets LSUIElement too, so this is belt and
// suspenders once bundled.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
