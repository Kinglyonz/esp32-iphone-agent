import SwiftUI

/// The constrained agent bubble shown when another activity (Screen Mirroring, always on during a run) also
/// occupies the Dynamic Island. Too small for words: just the face, its mood and gaze, and a colored dot
/// when it needs the user or has finished. The words live in the expanded island and on the Lock Screen.
struct AgentMinimalStatus: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        AgentFace(mood: state.mood, look: state.look, lookRange: 2.4, animated: false, showsTab: false)
            .padding(3)
            .frame(width: 24, height: 24)
            .overlay(alignment: .bottomTrailing) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            }
            .animation(.easeInOut(duration: 0.3), value: state.mood)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: state.statusAccessibilityText))
    }

    private var dot: Color? {
        if state.phase == .help { return .orange }
        guard state.finished else { return nil }
        return state.mood == .success ? .green : state.mood == .failure ? .red : nil
    }
}
