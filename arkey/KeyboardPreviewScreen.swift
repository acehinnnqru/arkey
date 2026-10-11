import SwiftUI
import RimeEngine

/// The keyboard's own views, rendered in the app. Kept on its own screen so the main screen can
/// give all of its space to the text field.
struct KeyboardPreviewScreen: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel
  @State private var asciiMode = false

  var body: some View {
    let _ = interfaceLocale
    let sideKeys = model.keyboardPreferences.spaceSideKeys(isASCII: asciiMode)
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(RimeLocalization.text("This preview uses the same views as the keyboard extension and shows appearance only."))
          .font(.footnote)
          .foregroundStyle(.secondary)
        Picker(RimeLocalization.text("Input mode"), selection: $asciiMode) {
          Text(RimeLocalization.text("Chinese keyboard")).tag(false)
          Text(RimeLocalization.text("English keyboard")).tag(true)
        }
        .pickerStyle(.segmented)
        KeyboardPreview(asciiMode: asciiMode, chineseInputOnly: model.keyboardPreferences.chineseInputOnly,
                        auxiliaryPrefix: model.keyboardPreferences.auxiliaryPrefix,
                        leftSpaceKey: sideKeys.left,
                        rightSpaceKey: sideKeys.right)
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
