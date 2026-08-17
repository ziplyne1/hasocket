// Owns the single in-process Daemon instance for the menu bar app. The menu
// bar app runs the same Daemon that `hasocket serve` runs from a terminal -
// no subprocess, no separate binary to supervise - so Start/Stop here just
// toggles whether the daemon is alive in this process.
import Foundation
import HASocketCore

@MainActor
final class DaemonController: ObservableObject {
    @Published private(set) var isServing = false
    @Published private(set) var connectionState: HAConnectionState = .disconnected
    @Published private(set) var statusMessage = "Stopped"

    private var daemon: Daemon?

    func start() {
        guard daemon == nil else { return }

        guard let config = HAConfigStore.load() else {
            statusMessage = "No config at \(HAConfigStore.configPath.path)"
            return
        }
        let entities = HAConfigStore.loadWatchedEntities()

        let d = Daemon()
        d.onStateChange = { [weak self] state in
            Task { @MainActor in self?.connectionState = state }
        }
        d.onLog = { [weak self] line in
            Task { @MainActor in self?.statusMessage = line }
        }
        d.start(config: config, watchedEntityIDs: entities)

        daemon = d
        isServing = true
    }

    func stop() {
        daemon?.stop()
        daemon = nil
        isServing = false
        connectionState = .disconnected
        statusMessage = "Stopped"
    }
}
