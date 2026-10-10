import SwiftUI
import RimeEngine
import UniformTypeIdentifiers

/// S2 §3's 自定义短语 screen: add, remove, import and export the phrase list.
struct CustomPhraseView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel

  @State private var newText = ""
  @State private var newCode = ""
  @State private var newWeight = ""
  @State private var isImporting = false
  @State private var isLoading = true
  @State private var mergeStrategy: RimeCustomPhraseMerge = .appendNew

  var body: some View {
    let _ = interfaceLocale
    List {
      if isLoading { ProgressView(RimeLocalization.text("Loading phrases…")) }
      Section {
        TextField(RimeLocalization.text("Phrase (for example, 你好)"), text: $newText)
        TextField(RimeLocalization.text("Code (for example, ni hao)"), text: $newCode)
        TextField(RimeLocalization.text("Weight (optional)"), text: $newWeight)
          .keyboardType(.decimalPad)
        Button(RimeLocalization.text("Add and deploy")) {
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
        Text(RimeLocalization.text("Add"))
      }

      Section(RimeLocalization.text("Phrases (\(String(model.customPhrases.count)))")) {
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
        Section(RimeLocalization.text("Unreadable lines")) {
          ForEach(model.rejectedPhraseLines, id: \.line) { entry in
            Text(RimeLocalization.text("Generation \(String(entry.line)): \(entry.text)"))
              .font(.caption2).foregroundStyle(.orange)
          }
        }
      }

      Section {
        Picker(RimeLocalization.text("Import mode"), selection: $mergeStrategy) {
          Text(RimeLocalization.text("Add new phrases only")).tag(RimeCustomPhraseMerge.appendNew)
          Text(RimeLocalization.text("Replace all")).tag(RimeCustomPhraseMerge.replaceAll)
          Text(RimeLocalization.text("Keep existing; ignore import")).tag(RimeCustomPhraseMerge.keepExisting)
        }
        Button(RimeLocalization.text("Import custom_phrase.txt…")) { isImporting = true }
        if let url = exported {
          ShareLink(item: url) { Text(RimeLocalization.text("Share exported custom_phrase.txt")) }
        } else {
          Button(RimeLocalization.text("Export custom_phrase.txt")) { exported = model.exportCustomPhrases() }
        }
      } header: {
        Text(RimeLocalization.text("Import and export"))
      } footer: {
        Text(RimeLocalization.text("Files use Rime’s plain text format and can be exchanged between phone and desktop. Import uses the selected mode and never overwrites silently.\n\(UserFacing.text(model.customPhraseURL.path))"))
      }

      if let error = model.errorMessage {
        UserFacing.errorRow(error)
      }
    }
    .disabled(isLoading)
    .navigationTitle(RimeLocalization.text("Custom phrases"))
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text],
                  allowsMultipleSelection: false) { result in
      switch result {
      case .failure(let error):
        model.errorMessage = RimeLocalization.message("Failed to select a file: \(String(describing: error))")
      case .success(let urls):
        guard let url = urls.first else { return }
        Task { await model.importCustomPhrases(from: url, strategy: mergeStrategy) }
      }
    }
    .task {
      isLoading = true
      await model.refreshCustomPhrases()
      isLoading = false
    }
  }

  /// Built in steps: as one expression the type checker gives up on it.
  private func subtitle(_ phrase: RimeCustomPhrase) -> String {
    guard let weight = phrase.weight else { return phrase.code }
    return RimeLocalization.text("\(phrase.code) · weight \(RimeCustomPhrase.format(weight))")
  }

  @State private var exported: URL?
}
