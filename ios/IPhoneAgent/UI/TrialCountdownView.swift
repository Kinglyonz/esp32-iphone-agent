import SwiftUI

struct TrialCountdownView: View {
    @ObservedObject var trial: TrialService

    var body: some View {
        if trial.lease != nil {
            HStack {
                Text("Free trial seconds remaining")
                Text(trial.remainingSeconds, format: .number).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}
