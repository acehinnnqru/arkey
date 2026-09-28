import Combine
import Foundation
import RimeEngine
import SwiftUI

/// S2 §3's 自定义短语 row: the file the user owns, edited in the app and then deployed.
///
/// The phrases live in `<user>/custom_phrase.txt` — Rime's own file, in Rime's own format — so the
/// desktop and the phone can exchange it as plain text, and so a user who prefers an editor keeps
/// working.
@MainActor
extension RimeAppModel {
  var customPhraseURL: URL {
    workspace.userData.appendingPathComponent("custom_phrase.txt")
  }

  func refreshCustomPhrases() {
    do {
      let result = try RimeCustomPhraseFile.load(from: customPhraseURL)
      customPhrases = result.phrases
      rejectedPhraseLines = result.rejected
    } catch {
      customPhrases = []
      rejectedPhraseLines = []
      errorMessage = "读取自定义短语失败：" + String(describing: error)
    }
  }

  /// Writes the whole file and deploys: a phrase that is not deployed does not exist as far as the
  /// keyboard is concerned.
  func saveCustomPhrases(_ phrases: [RimeCustomPhrase]) async {
    do {
      try RimeCustomPhraseFile.save(phrases, to: customPhraseURL)
      customPhrases = phrases
      await deploy(profileID: activeProfileID ?? profiles.first?.id ?? "")
      refreshCustomPhrases()
    } catch {
      errorMessage = "写入自定义短语失败：" + String(describing: error)
    }
  }

  func addCustomPhrase(text: String, code: String, weight: Double?) async {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty, !trimmedCode.isEmpty else { return }
    var phrases = customPhrases
    phrases.append(RimeCustomPhrase(text: trimmedText, code: trimmedCode, weight: weight))
    await saveCustomPhrases(phrases)
  }

  func removeCustomPhrase(at offsets: IndexSet) async {
    var phrases = customPhrases
    phrases.remove(atOffsets: offsets)
    await saveCustomPhrases(phrases)
  }

  /// An imported file meets what is there under an explicit strategy — never a silent overwrite.
  func importCustomPhrases(from url: URL, strategy: RimeCustomPhraseMerge) async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let incoming = try RimeCustomPhraseFile.load(from: url)
      let merged = RimeCustomPhraseFile.merge(incoming.phrases, into: customPhrases,
                                              strategy: strategy)
      importWarnings = ["导入自定义短语：" + String(incoming.phrases.count) + " 条，"
                        + String(merged.count - customPhrases.count) + " 条新增"]
      await saveCustomPhrases(merged)
    } catch {
      errorMessage = "导入自定义短语失败：" + String(describing: error)
    }
  }

  func exportCustomPhrases() -> URL? {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? workspace.root
    let url = documents.appendingPathComponent("custom_phrase.txt")
    do {
      try RimeCustomPhraseFile.save(customPhrases, to: url)
      return url
    } catch {
      errorMessage = "导出自定义短语失败：" + String(describing: error)
      return nil
    }
  }
}
