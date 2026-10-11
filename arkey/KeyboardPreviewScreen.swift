import SwiftUI
import RimeEngine

/// The keyboard's own views, rendered in the app. Kept on its own screen so the main screen can
/// give all of its space to the text field.
struct KeyboardPreviewScreen: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel

  var body: some View {
    let _ = interfaceLocale
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(RimeLocalization.text("This preview uses the same views as the keyboard extension and shows appearance only."))
          .font(.footnote)
          .foregroundStyle(.secondary)
        KeyboardPreview(auxiliaryPrefix: model.keyboardPreferences.auxiliaryPrefix,
                        leftSpaceKey: model.keyboardPreferences.leftSpaceKey,
                        rightSpaceKey: model.keyboardPreferences.rightSpaceKey)
          .frame(height: KeyboardMetrics.totalHeight(needsGlobeRow: true))
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }
      .padding()
    }
    .navigationTitle(RimeLocalization.text("Keyboard preview"))
    .task { await model.refreshPreferences() }
  }
}

#Preview {
  NavigationStack { KeyboardPreviewScreen(model: RimeAppModel.shared) }
}
