import SwiftUI
import RimeEngine

/// S2 §3's 标点 screen: which symbols table the schema imports.
///
/// 全角/半角 and 中英标点 are *switch* states rather than tables, so they stay on the 方案 screen — this
/// one says so instead of duplicating them.
struct PunctuationView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel
  @State private var isLoading = true

  var body: some View {
    let _ = interfaceLocale
    List {
      Section {
        ForEach(model.punctuationChoices, id: \.preset.id) { choice in
          Button {
            Task { await model.setPunctuationPreset(choice.preset) }
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(choice.preset.displayName).font(.body)
                Text(choice.preset.note).font(.caption2).foregroundStyle(.secondary)
                if !choice.isAvailable {
                  Text(RimeLocalization.text("This profile does not include \((choice.preset.requiresFile ?? ""))"))
                    .font(.caption2).foregroundStyle(.orange)
                }
              }
              Spacer()
              if model.currentPunctuationPreset == choice.preset.importPreset {
                Image(systemName: "checkmark")
              }
            }
          }
          .disabled(!choice.isAvailable)
        }
      } header: {
        Text(RimeLocalization.text("symbol table"))
      } footer: {
        Text(RimeLocalization.text("Choose a symbol table and redeploy. Full/half-width and Chinese/English punctuation remain controlled by the schema switches."))
      }
      if let error = model.errorMessage { UserFacing.errorRow(error) }
    }
    .modifier(SettingsLoadingPresentation(isLoading: isLoading))
    .navigationTitle(RimeLocalization.text("Punctuation"))
    .task {
      isLoading = true
      await model.refreshSettings()
      isLoading = false
    }
  }
}
