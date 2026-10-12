import Foundation
import RimeEngine

@MainActor
extension RimeAppModel {
  /// Compatibility failure is independent of profile activation. Keep the last readable library
  /// visible and show the failure in its own section rather than reporting deployment as failed.
  func refreshPersonalDictionary(applyWords: Bool = true) async {
    guard !isUpdatingPersonalDictionary, !isDeploying, !isImporting else { return }
    isUpdatingPersonalDictionary = true
    defer { isUpdatingPersonalDictionary = false }
    let workspace = self.workspace
    let engine = self.engine
    do {
      let snapshot = try await Task.detached(priority: .utility) {
        let outcome = try RimePersonalDictionaryService(workspace: workspace, engine: engine)
          .synchronize(applyWords: applyWords)
        let sources = outcome.library.latestSources.map { source in
          let entries = RimeUserDictionarySnapshot.parse(text: source.snapshot)?.entries ?? []
          let recognized = entries.filter { RimeMandarinCode.normalize($0.code) != nil }.count
          return source.dictionary + ":compatible=" + String(source.isPlainMandarin)
            + ",entries=" + String(entries.count) + ",recognizedCodes=" + String(recognized)
        }.joined(separator: ";")
        return (outcome, outcome.library.words.filter { !$0.isDeleted }.count, outcome.library.unconvertedCount, sources)
      }.value
      let outcome = snapshot.0
      RimeProbeLog(url: workspace.log.appendingPathComponent("probe.jsonl"))
        .append(RimeProbeRecord(phase: "app.personalDictionary", message: "sources=[" + snapshot.3
          + "] words=" + String(snapshot.1) + " unconverted=" + String(snapshot.2)
          + " imported=" + String(outcome.imported) + " unsupported=["
          + outcome.unsupportedTargets.joined(separator: ",") + "] failures=["
          + outcome.failures.joined(separator: ";") + "]"))
      ProbeLogLocation.mirrorIntoAppContainer()
      personalDictionary = outcome.library
      personalDictionaryWordCount = snapshot.1
      personalDictionaryUnconvertedCount = snapshot.2
      if !outcome.failures.isEmpty {
        personalDictionaryMessage = RimeLocalization.message("Some source records or compatible words could not be updated. Retained sources are unchanged and remain exportable. Details: \(outcome.failures.joined(separator: "; "))")
      } else if !outcome.unsupportedTargets.isEmpty {
        personalDictionaryMessage = RimeLocalization.message("Automatic compatibility is not available for \(outcome.unsupportedTargets.joined(separator: ", ")). Its original records are retained without conversion.")
      } else {
        personalDictionaryMessage = RimeLocalization.message("Personal sources are up to date. Compatible schemes receive missing words; existing learning scores are kept.")
      }
    } catch {
      RimeProbeLog(url: workspace.log.appendingPathComponent("probe.jsonl"))
        .append(RimeProbeRecord(phase: "app.personalDictionary.failed", message: String(describing: error)))
      ProbeLogLocation.mirrorIntoAppContainer()
      // A busy keyboard must not prevent exporting the sources already saved by the app.
      let snapshot = await Task.detached(priority: .utility) {
        guard let library = try? RimePersonalDictionaryService(workspace: workspace, engine: engine).load() else {
          return (Optional<RimePersonalDictionary>.none, 0, 0)
        }
        return (Optional(library), library.words.filter { !$0.isDeleted }.count, library.unconvertedCount)
      }.value
      personalDictionary = snapshot.0
      personalDictionaryWordCount = snapshot.1
      personalDictionaryUnconvertedCount = snapshot.2
      personalDictionaryMessage = RimeLocalization.message("Personal sources could not be refreshed. Close the keyboard and retry; previously retained sources can still be exported. Details: \(String(describing: error))")
    }
  }

  func exportPersonalDictionary() async -> URL? {
    guard !isUpdatingPersonalDictionary else { return nil }
    await refreshPersonalDictionary(applyWords: false)
    let workspace = self.workspace
    let engine = self.engine
    let url = workspace.root.appendingPathComponent("exports")
      .appendingPathComponent("arkey-personal-dictionary-" + UUID().uuidString + ".zip")
    do {
      try await Task.detached(priority: .utility) {
        try RimePersonalDictionaryService(workspace: workspace, engine: engine).export(to: url)
      }.value
      return url
    } catch {
      personalDictionaryMessage = RimeLocalization.message("Failed to export personal sources: \(String(describing: error))")
      return nil
    }
  }

  func resumePersonalDictionary(_ name: String) async {
    guard !isUpdatingPersonalDictionary, !isDeploying, !isImporting, !isSyncing else { return }
    do {
      let workspace = self.workspace
      let engine = self.engine
      try await Task.detached(priority: .utility) {
        try RimePersonalDictionaryService(workspace: workspace, engine: engine).resume(name)
      }.value
      await refreshDictionariesInBackground()
    } catch {
      personalDictionaryMessage = RimeLocalization.message("Failed to resume personal words for \(name): \(String(describing: error))")
    }
  }
}
