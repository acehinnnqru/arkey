import Combine
import Foundation
import RimeEngine
import SwiftUI

/// S5-AC6: a schema that has turned learning off leaves sync disabled, and the screen says why rather
/// than showing an error. S2 owns the switch; this is the consequence.
@MainActor
extension RimeAppModel {
  /// Read with the dictionary snapshot, never while SwiftUI is drawing the page.
  nonisolated static func dictionarySyncDisabledReason(engine: RimeEngine) -> RimeLocalizedMessage? {
    let current = try? engine.currentSchema()
    guard let id = current.flatMap({ $0.isEmpty ? nil : $0 }) ?? (try? engine.schemaIDs().first)
    else { return nil }
    // The lookup is the engine's (`RimeUserDictionaryLearning`), so the key name and the meaning of false are
    // tested rather than repeated in a sentence here.
    let enabled = try? RimeUserDictionaryLearning.isEnabled(engine: engine, schemaID: id)
    guard enabled == false else { return nil }
    return RimeLocalization.message("Current scheme (\(id)) has disabled its user dictionary (translator/enable_user_dict). It cannot learn new words or sync. Enable it in Scheme and input to resume learning.")
  }

  /// The dictionary rows the screen shows, filtered by the search field.
  func filteredDictionaries(matching query: String) -> [RimeUserDictionaryReport.Entry] {
    guard let report = dictionaryReport else { return [] }
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return report.dictionaries }
    return report.dictionaries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
  }
}
