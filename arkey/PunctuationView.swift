import SwiftUI
import RimeEngine

/// S2 §3's 标点 screen: which symbols table the schema imports.
///
/// 全角/半角 and 中英标点 are *switch* states rather than tables, so they stay on the 方案 screen — this
/// one says so instead of duplicating them.
struct PunctuationView: View {
  @ObservedObject var model: RimeAppModel

  var body: some View {
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
                  Text("该配置里没有 " + (choice.preset.requiresFile ?? ""))
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
        Text("符号表")
      } footer: {
        Text("写入 punctuator/import_preset 并重新部署。全角/半角与中英标点在「方案与输入」的开关一节里，它们不是表。")
      }
      if let error = model.errorMessage { Section("错误") { Text(error).font(.caption).foregroundStyle(.red) } }
    }
    .navigationTitle("标点")
    .task { model.refreshSettings() }
  }
}
