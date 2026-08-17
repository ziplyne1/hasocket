import SwiftUI
import AppKit
import HASocketCore

struct MenuBarContentView: View {
    @EnvironmentObject private var controller: DaemonController
    @State private var cliLinked = CLIInstaller.isSymlinkCurrent
    @State private var cliError: String?
    @State private var configExists = HAConfigStore.exists
    @State private var showingSetup = false

    var body: some View {
        if !configExists || showingSetup {
            ConfigSetupView(
                onSaved: {
                    configExists = true
                    showingSetup = false
                    controller.start()
                },
                onCancel: configExists ? { showingSetup = false } : nil
            )
        } else {
            mainView
        }
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("hasocket")
                .font(.headline)

            Label(statusText, systemImage: statusIcon)
                .foregroundStyle(statusColor)

            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button(controller.isServing ? "Stop" : "Start") {
                    controller.isServing ? controller.stop() : controller.start()
                }
                .keyboardShortcut(controller.isServing ? "." : "s")

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            
            Divider()

            HStack {
                if #available(macOS 14.0, *) {
                    Button(cliLinked ? "CLI Installed ✓" : "Install CLI to ~/.local/bin") {
                        installCLI()
                    }
                    .buttonStyle(.accessoryBar)
                    .disabled(cliLinked)
                    
                    Spacer()
                    
                    Button("Edit Token") {
                        showingSetup = true
                    }
                    .buttonStyle(.accessoryBar)
                } else {
                    Button(cliLinked ? "CLI Installed ✓" : "Install CLI to ~/.local/bin") {
                        installCLI()
                    }
                    .disabled(cliLinked)
                    
                    Spacer()
                    
                    Button("Edit Token") {
                        showingSetup = true
                    }
                }
            }

            if let cliError {
                Text(cliError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var statusText: String {
        switch controller.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return controller.isServing ? "Reconnecting…" : "Stopped"
        }
    }

    private var statusIcon: String {
        switch controller.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath.circle"
        case .disconnected: return controller.isServing ? "exclamationmark.circle.fill" : "circle"
        }
    }

    private var statusColor: Color {
        switch controller.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return controller.isServing ? .red : .secondary
        }
    }

    private func installCLI() {
        do {
            try CLIInstaller.installSymlink()
            cliError = nil
            cliLinked = true
        } catch {
            cliError = error.localizedDescription
        }
    }
}
