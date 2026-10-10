import SwiftUI
import RimeEngine

/// S2 §3's 按键 screen: a curated set, not a free editor.
///
/// The list is composed into `key_binder/bindings` the way 模糊音 is composed into `speller/algebra`:
/// the catalogue owns every binding it can generate, so an option that is off removes its own entries
/// and toggling twice cannot accumulate duplicates.
struct KeyBindingsView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel
  @State private var isLoading = true

  var body: some View {
    let _ = interfaceLocale
    List {
      if isLoading { ProgressView(RimeLocalization.text("Loading settings…")) }
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
        Text(RimeLocalization.text("Key bindings"))
      } footer: {
        Text(RimeLocalization.text("Character selection conflicts with paging using [ and ]: disable one before using the other.\nChanges are saved to key_binder/bindings and deployed again."))
      }
      if let error = model.errorMessage { UserFacing.errorRow(error) }
    }
    .disabled(isLoading)
    .navigationTitle(RimeLocalization.text("Keys"))
    .task {
      isLoading = true
      await model.refreshKeyBindings()
      isLoading = false
    }
  }
}
