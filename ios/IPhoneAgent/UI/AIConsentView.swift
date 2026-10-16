import SwiftUI

/// What goes to the model provider, before the first request to it. Agree only after reading to the end.
struct AIConsentSheet: View {
    let baseURL: String
    var onAgree: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var readToEnd = false
    @State private var agreed = false

    private var host: String { AIConsent.host(baseURL) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("To work, ESP32 Agent sends data to the AI service you chose. Nothing is sent until you agree.")
                }
                Section("Sent to") {
                    Label { Text(verbatim: host).font(.body.monospaced()) } icon: { Image(systemName: "server.rack") }
                }
                Section("What is sent") {
                    Label("A screenshot of your mirrored screen at every step of a run, so the AI can see it", systemImage: "photo")
                    Label("The task you type and the steps so far", systemImage: "text.bubble")
                    Label("Your API key, to sign in to that service", systemImage: "key")
                }
                Section("When") {
                    Label("Only when you start a run, test the connection, check the calibration or save an intent", systemImage: "hand.tap")
                }
                Section {
                    Text("Screenshots may show anything on your screen. \(host) handles them under its own privacy policy and terms; the ESP32 Agent developer never receives them. You can withdraw this anytime in Settings › Privacy.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("I agree to send this data to \(host)", isOn: $agreed)
                        .disabled(!readToEnd)
                        .onAppear { readToEnd = true }  // the last row: the list was scrolled to the end
                }
            }
            .navigationTitle("Send to AI Service?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agree") {
                        AIConsent.grant(baseURL)
                        Analytics.capture("ai_consent", ["granted": true])
                        onAgree()
                        dismiss()
                    }
                    .disabled(!agreed)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// In the model form: the state of the agreement for the current host, and the button that asks for it.
struct AIConsentRow: View {
    @ObservedObject var settings: Settings
    @State private var asking = false

    var body: some View {
        if AIConsent.store && settings.isConfigured {
            let host = AIConsent.host(settings.baseURL)
            Button { asking = true } label: {
                Label {
                    Text(AIConsent.granted(settings.baseURL) ? "Allowed to send to \(host)" : "Allow sending to \(host)…")
                } icon: {
                    Image(systemName: AIConsent.granted(settings.baseURL) ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(AIConsent.granted(settings.baseURL) ? Palette.ok : .orange)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(AIConsent.granted(settings.baseURL))
            .sheet(isPresented: $asking) {
                AIConsentSheet(baseURL: settings.baseURL) { settings.consentChanged() }
            }
        }
    }
}

/// Settings › Privacy: the agreed host, and withdraw.
struct AIConsentSection: View {
    @ObservedObject var settings: Settings

    var body: some View {
        if AIConsent.store {
            Section {
                if let host = AIConsent.grantedHost {
                    LabeledContent("Allowed", value: host)
                    Button("Withdraw", role: .destructive) {
                        AIConsent.revoke()
                        Analytics.capture("ai_consent", ["granted": false])
                        settings.consentChanged()
                    }
                } else {
                    Text("No AI service allowed. Runs ask first.").foregroundStyle(.secondary)
                }
            } header: {
                Text("AI service")
            } footer: {
                Text("Screenshots and your task go only to the AI service you allowed, and only during runs, tests and intent saving.")
            }
        }
    }
}
