import SwiftUI
import RimeEngine

/// The keyboard's own views, rendered in the app. Kept on its own screen so the main screen can
/// give all of its space to the text field.
struct KeyboardPreviewScreen: View {
  @ObservedObject var model: RimeAppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("与扩展共用同一套视图代码，这里只用于查看外观。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        KeyboardPreview(auxiliaryPrefix: model.keyboardPreferences.auxiliaryPrefix,
                        auxiliaryKeySide: model.keyboardPreferences.auxiliaryKeySide)
          .frame(height: KeyboardMetrics.totalHeight(needsGlobeRow: true))
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }
      .padding()
    }
    .navigationTitle("键盘预览")
    .onAppear { model.refreshPreferences() }
  }
}

#Preview {
  NavigationStack { KeyboardPreviewScreen(model: RimeAppModel.shared) }
}
