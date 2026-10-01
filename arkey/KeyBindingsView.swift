import SwiftUI
import RimeEngine

/// S2 §3's 按键 screen: a curated set, not a free editor.
///
/// The list is composed into `key_binder/bindings` the way 模糊音 is composed into `speller/algebra`:
/// the catalogue owns every binding it can generate, so an option that is off removes its own entries
/// and toggling twice cannot accumulate duplicates.
struct KeyBindingsView: View {
  @ObservedObject var model: RimeAppModel

  var body: some View {
    List {
      Section {
        ForEach(RimeKeyBindings.options) { option in
          Toggle(option.displayName, isOn: Binding(
            get: { model.enabledKeyBindingOptions.contains(option.id) },
            set: { isOn in
              var enabled = model.enabledKeyBindingOptions
              if isOn {
                if !enabled.contains(option.id) { enabled.append(option.id) }
              } else {
                enabled.removeAll { $0 == option.id }
              }
              Task { await model.setKeyBindingOptions(enabled) }
            }))
          .disabled(option.id == "word_selection"
                    && model.enabledKeyBindingOptions.contains("page_bracket"))
        }
      } header: {
        Text("按键绑定")
      } footer: {
        Text("以词定字与「翻页：[ 和 ]」冲突：同一个键不能既翻页又取字，先关掉一个。\n"
             + "改动写入 key_binder/bindings 并重新部署。")
      }
      SettingsDeployFooter(model: model)
      if let error = model.errorMessage { UserFacing.errorRow(error) }
    }
    .navigationTitle("按键")
    .task { model.refreshKeyBindings() }
  }
}
