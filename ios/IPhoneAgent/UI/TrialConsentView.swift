import SwiftUI

/// Shared by setup and privacy settings; remote trial consent is independent of local exports.
struct TrialConsentView: View {
    @ObservedObject var trial: TrialService
    @State private var showingConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Free trial availability")
                Spacer()
                Text(verbatim: trial.status).font(.body.monospaced())
            }
            Text("Up to 60 seconds per task. This installation has up to 3 trial claims; each IP has 10. Either limit makes the route busy until the operator resets it. The installation identity is not a permanent physical-device identifier.")
                .font(.footnote).foregroundStyle(.secondary)
            if trial.consented {
                Text("Remote trial recording is enabled.").font(.footnote)
                Button("Withdraw recording consent", role: .destructive) { trial.consented = false }
            } else {
                Button("Review trial data consent") { showingConsent = true }
            }
            if trial.consented {
                Button("Trial data details") { showingConsent = true }
                    .font(.footnote).tint(.secondary)
            }
            Link("Privacy policy", destination: URL(string: "https://llm.handsy.tech/privacy")!)
                .font(.footnote).tint(.secondary)
            if let message = trial.message {
                Text(verbatim: message).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Refresh availability") { Task { await trial.refreshStatus() } }
                .disabled(trial.checking)
            if trial.checking { ProgressView("Checking trial availability…") }
        }
        .sheet(isPresented: $showingConsent) {
            NavigationStack {
                List {
                    Section {
                        Text("Handsy sends the prompts, screenshots and model replies used for a free trial task through a Hong Kong relay to Henry's DGX Spark in China. The service privately stores these contents and request timing for troubleshooting and improving the service. Screenshots may contain private information from other apps.")
                        Text("Do not use the free trial for passwords, payment details, private conversations or other sensitive tasks. You can use your own model provider instead.")
                    } header: { Text("Remote trial recording") }
                    Section {
                        Text("The operator manages trial records manually. There is no automatic deletion. The service stops accepting trial data at its configured 5 GiB storage cap. Withdrawing consent stops future trial uploads and ends an active trial; it does not delete earlier records.")
                        Text("For deletion of existing trial records, contact the operator and use the installation identifier below. No account is required.")
                        Text(verbatim: trial.deviceID).font(.footnote.monospaced()).textSelection(.enabled)
                        Link("Privacy policy", destination: URL(string: "https://llm.handsy.tech/privacy")!)
                        Link("Contact the operator", destination: URL(string: "mailto:support@handsy.tech")!)
                    } header: { Text("Your choice and existing records") }
                    if !trial.consented {
                        Section {
                            Button("Agree and enable remote trial recording") {
                                trial.consented = true
                                showingConsent = false
                            }
                        }
                    }
                }
                .navigationTitle("Free Trial Data")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingConsent = false } }
                }
            }
        }
        .task { await trial.refreshStatus() }
    }
}
