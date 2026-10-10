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
  private enum Field: Hashable { case text, code, weight }
  @FocusState private var focusedField: Field?
  @State private var isSaving = false

  var body: some View {
    let _ = interfaceLocale
    List {
      if isLoading { ProgressView(RimeLocalization.text("Loading phrases…")) }
      Section {
        TextField(RimeLocalization.text("Phrase (for example, 你好)"), text: $newText)
          .focused($focusedField, equals: .text)
        TextField(RimeLocalization.text("Code (for example, ni hao)"), text: $newCode)
          .focused($focusedField, equals: .code)
        TextField(RimeLocalization.text("Weight (optional)"), text: $newWeight)
          .keyboardType(.decimalPad)
          .focused($focusedField, equals: .weight)
        Button(RimeLocalization.text("Add and deploy")) {
          let text = newText
          let code = newCode
          let weight = Double(newWeight.trimmingCharacters(in: .whitespaces))
          let previousCount = model.customPhrases.count
          save {
            await model.addCustomPhrase(text: text, code: code, weight: weight)
            // A deployment refusal leaves the saved entry in the list. Retry deployment
            // rather than offering the same draft for a second insertion.
            if model.customPhrases.count > previousCount {
              newText = ""
              newCode = ""
              newWeight = ""
            }
          }
        }
        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty
                  || newCode.trimmingCharacters(in: .whitespaces).isEmpty)
      } header: {
        Text(RimeLocalization.text("Add"))
      }

      Section {
        NavigationLink {
          CustomPhraseListView(model: model)
        } label: {
          Text(RimeLocalization.text("Phrases (\(model.customPhrases.count.formatted(.number.locale(interfaceLocale))))"))
        }
      }

      Section(RimeLocalization.text("Deployment")) {
        Button(RimeLocalization.text("Redeploy")) {
          save { await model.redeployActiveProfile() }
        }
        .accessibilityIdentifier("custom-phrases-redeploy")
        if let message = model.deployMessage, model.errorMessage == nil {
          Text(message.text).font(.caption).foregroundStyle(.secondary)
        }
        if let error = model.errorMessage {
          UserFacing.errorRow(error)
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
    }
    .disabled(isLoading || isSaving || model.isDeploying)
    .navigationTitle(RimeLocalization.text("Custom phrases"))
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text],
                  allowsMultipleSelection: false) { result in
      switch result {
      case .failure(let error):
        model.errorMessage = RimeLocalization.message("Failed to select a file: \(String(describing: error))")
      case .success(let urls):
        guard let url = urls.first else { return }
        save { await model.importCustomPhrases(from: url, strategy: mergeStrategy) }
      }
    }
    .task {
      isLoading = true
      await model.refreshCustomPhrases()
      isLoading = false
    }
  }

  private func save(_ operation: @escaping @MainActor () async -> Void) {
    guard !isSaving else { return }
    // The Arkey keyboard owns the shared dictionaries while a phrase field has focus.
    // Dismiss it before deployment; the coordinator waits for its disappearance callback.
    focusedField = nil
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      await operation()
    }
  }

  @State private var exported: URL?
}

private struct CustomPhraseListView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel
  @State private var isLoading = true
  @State private var isRemoving = false

  var body: some View {
    let _ = interfaceLocale
    List {
      if isLoading {
        ProgressView(RimeLocalization.text("Loading phrases…"))
      } else if model.customPhrases.isEmpty {
        Text(RimeLocalization.text("No custom phrases yet."))
          .foregroundStyle(.secondary)
      } else {
        Section(RimeLocalization.text("Phrases (\(model.customPhrases.count.formatted(.number.locale(interfaceLocale))))")) {
          ForEach(Array(model.customPhrases.enumerated()), id: \.offset) { _, phrase in
            VStack(alignment: .leading, spacing: 2) {
              Text(phrase.text).font(.body)
              Text(subtitle(phrase)).font(.caption).foregroundStyle(.secondary)
            }
          }
          .onDelete { offsets in
            guard !isRemoving else { return }
            isRemoving = true
            Task { @MainActor in
              defer { isRemoving = false }
              await model.removeCustomPhrase(at: offsets)
            }
          }
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
      if let error = model.errorMessage {
        UserFacing.errorRow(error)
      }
    }
    .navigationTitle(RimeLocalization.text("Phrase list"))
    .disabled(isLoading || isRemoving || model.isDeploying)
    .task {
      await model.refreshCustomPhrases()
      isLoading = false
    }
  }

  private func subtitle(_ phrase: RimeCustomPhrase) -> String {
    guard let weight = phrase.weight else { return phrase.code }
    return RimeLocalization.text("\(phrase.code) · weight \(RimeCustomPhrase.format(weight))")
  }
}
