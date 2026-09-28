import SwiftUI
import RimeEngine
import UniformTypeIdentifiers

/// S2 §3's 自定义短语 screen: add, remove, import and export the phrase list.
struct CustomPhraseView: View {
  @ObservedObject var model: RimeAppModel

  @State private var newText = ""
  @State private var newCode = ""
  @State private var newWeight = ""
  @State private var isImporting = false
  @State private var mergeStrategy: RimeCustomPhraseMerge = .appendNew

  var body: some View {
    List {
      Section {
        TextField("词条（例如 你好）", text: $newText)
        TextField("编码（例如 ni hao）", text: $newCode)
        TextField("权重（可留空）", text: $newWeight)
          .keyboardType(.decimalPad)
        Button("添加并部署") {
          let weight = Double(newWeight.trimmingCharacters(in: .whitespaces))
          Task {
            await model.addCustomPhrase(text: newText, code: newCode, weight: weight)
            newText = ""
            newCode = ""
            newWeight = ""
          }
        }
        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty
                  || newCode.trimmingCharacters(in: .whitespaces).isEmpty)
      } header: {
        Text("新增")
      }

      Section("短语（" + String(model.customPhrases.count) + "）") {
        ForEach(Array(model.customPhrases.enumerated()), id: \.offset) { _, phrase in
          VStack(alignment: .leading, spacing: 2) {
            Text(phrase.text).font(.body)
            Text(subtitle(phrase))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .onDelete { offsets in
          Task { await model.removeCustomPhrase(at: offsets) }
        }
      }

      if !model.rejectedPhraseLines.isEmpty {
        Section("无法读取的行") {
          ForEach(model.rejectedPhraseLines, id: \.line) { entry in
            Text("第 " + String(entry.line) + " 行：" + entry.text)
              .font(.caption2).foregroundStyle(.orange)
          }
        }
      }

      Section {
        Picker("导入方式", selection: $mergeStrategy) {
          Text("只添加新词条").tag(RimeCustomPhraseMerge.appendNew)
          Text("整表替换").tag(RimeCustomPhraseMerge.replaceAll)
          Text("保留现有，忽略导入").tag(RimeCustomPhraseMerge.keepExisting)
        }
        Button("导入 custom_phrase.txt…") { isImporting = true }
        if let url = exported {
          ShareLink(item: url) { Text("分享导出的 custom_phrase.txt") }
        } else {
          Button("导出 custom_phrase.txt") { exported = model.exportCustomPhrases() }
        }
      } header: {
        Text("导入导出")
      } footer: {
        Text("文件是 Rime 自己的纯文本格式，所以手机和电脑可以直接交换；导入按上面的方式合并，绝不静默覆盖。\n"
             + model.customPhraseURL.path)
      }

      if let error = model.errorMessage {
        Section("错误") { Text(error).font(.caption).foregroundStyle(.red) }
      }
    }
    .navigationTitle("自定义短语")
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text],
                  allowsMultipleSelection: false) { result in
      switch result {
      case .failure(let error):
        model.errorMessage = "选择文件失败：" + String(describing: error)
      case .success(let urls):
        guard let url = urls.first else { return }
        Task { await model.importCustomPhrases(from: url, strategy: mergeStrategy) }
      }
    }
    .task { model.refreshCustomPhrases() }
  }

  /// Built in steps: as one expression the type checker gives up on it.
  private func subtitle(_ phrase: RimeCustomPhrase) -> String {
    guard let weight = phrase.weight else { return phrase.code }
    return phrase.code + " · 权重 " + RimeCustomPhrase.format(weight)
  }

  @State private var exported: URL?
}
