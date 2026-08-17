// Tiny menu bar shell around the same Daemon that `hasocket serve` runs
// from a terminal. Starts the daemon automatically on launch; Start/Stop in
// the menu just toggles it within this process - add this app as a Login
// Item (see build-app.sh) to have it running whenever you're logged in,
// with no terminal window needed.
import SwiftUI
import HASocketCore

@main
struct HASocketMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller: DaemonController

    init() {
        let controller = DaemonController()
        _controller = StateObject(wrappedValue: controller)
        controller.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.connectionState == .connected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
