import Combine
import Foundation
import RimeEngine
import SwiftUI

/// S5-AC6: a schema that has turned learning off leaves sync disabled, and the screen says why rather
/// than showing an error. S2 owns the switch; this is the consequence.
@MainActor
extension RimeAppModel {
  /// The sentence the dictionary screen shows when sync has nothing to do, or nil when it has.
  var syncDisabledReason: String? {
    guard let id = settingsSchemaID else { return nil }
    // The lookup is the engine's (`RimeUserDictionaryLearning`), so the key name and the meaning of false are
    // tested rather than repeated in a sentence here.
    let enabled = try? RimeUserDictionaryLearning.isEnabled(engine: engine, schemaID: id)
    guard enabled == false else { return nil }
    return "当前方案（" + id + "）关闭了用户词典（translator/enable_user_dict），"
      + "所以不会再学新词，同步也就没有内容。在「方案与输入」里打开它就会重新启用学习。"
  }

  /// The dictionary rows the screen shows, filtered by the search field.
  func filteredDictionaries(matching query: String) -> [RimeUserDictionaryReport.Entry] {
    guard let report = dictionaryReport else { return [] }
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return report.dictionaries }
    return report.dictionaries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
  }
}
