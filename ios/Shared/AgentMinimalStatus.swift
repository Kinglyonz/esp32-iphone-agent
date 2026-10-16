import SwiftUI

/// The constrained agent bubble shown when another activity also occupies the Dynamic Island.
struct AgentMinimalStatus: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        Text(verbatim: state.minimalStatusText)
            .font(.caption2.bold())
            .foregroundStyle(state.phase == .help ? .orange : .white)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 2)
            .frame(width: 36, height: 24)
            .accessibilityLabel(Text(verbatim: state.statusAccessibilityText))
    }
}
