import SwiftUI
import RimeEngine

/// S2 §6: "Every screen that writes shows the same two-state footer" — 已修改，待部署 while the write is
/// on its way, 已生效 once the deploy has finished. One view for every screen that writes, and the words
/// come from `RimeSettingsFooterState` so they cannot drift between screens.
struct SettingsDeployFooter: View {
  @ObservedObject var model: RimeAppModel

  var body: some View {
    let state = model.settingsFooter
    Section {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: symbol(state))
        Text(state.text).font(.caption)
        Spacer(minLength: 0)
      }
      .foregroundStyle(state.isFailure ? Color.orange : Color.secondary)
    }
  }

  private func symbol(_ state: RimeSettingsFooterState) -> String {
    if state.isPending { return "clock" }
    if state.isFailure { return "exclamationmark.triangle" }
    switch state {
    case .applied: return "checkmark.circle"
    case .unchanged, .pending, .failed: return "circle.dashed"
    }
  }
}
