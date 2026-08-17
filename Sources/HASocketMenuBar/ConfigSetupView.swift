// First-run (and "Edit Server & Token…") form for writing
// ~/.config/hasocket/config.json. Home Assistant long-lived access tokens
// are created under Profile > Security > Long-Lived Access Tokens.
import SwiftUI
import HASocketCore

struct ConfigSetupView: View {
    let onSaved: () -> Void
    let onCancel: (() -> Void)?

    @State private var baseURL: String
    @State private var token: String = ""
    @State private var error: String?

    init(onSaved: @escaping () -> Void, onCancel: (() -> Void)?) {
        self.onSaved = onSaved
        self.onCancel = onCancel
        _baseURL = State(initialValue: HAConfigStore.load()?.baseURL ?? "http://homeassistant.local:8123")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect to Home Assistant")
                .font(.headline)

            Text("Base URL")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("http://homeassistant.local:8123", text: $baseURL)
                .textFieldStyle(.roundedBorder)

            Text("Long-lived access token")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Profile → Security → Long-Lived Access Tokens", text: $token)
                .textFieldStyle(.roundedBorder)

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let onCancel {
                    Button("Cancel", action: onCancel)
                }

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func save() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        do {
            try HAConfigStore.save(baseURL: trimmedURL, token: token)
            error = nil
            onSaved()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
