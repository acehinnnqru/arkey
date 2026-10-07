import Combine
import Foundation
import RimeEngine
import SwiftUI

/// The keyboard's own settings (S2 §3's last row, S3 §4/§5).
///
/// Most values live in the app group's `UserDefaults`. The auxiliary prefix also updates
/// the active schema's Rime patch and triggers a deploy so the engine accepts the same key.
@MainActor
extension RimeAppModel {
  var preferencesStore: RimeKeyboardPreferencesStore? {
    RimeKeyboardPreferencesStore.appGroup()
  }

  func refreshPreferences() {
    keyboardPreferences = preferencesStore?.value ?? .standard
    refreshAuxiliarySpelling()
    if deployInFlight == nil, let schemaID = settingsSchemaID ?? (try? engine.schemaIDs().first),
       let prefix = try? engine.schemaValue("key_binder/search", schemaID: schemaID)?.stringValue,
       let normalized = RimeKeyboardPreferences.normalizedAuxiliaryPrefix(prefix) {
      keyboardPreferences.auxiliaryPrefix = normalized
    }
  }

  func refreshAuxiliarySpelling() {
    guard deployInFlight == nil else { return }
    let patch = RimePatch(engine: engine, configID: "radical_pinyin")
    if let value = try? patch.userValue("speller/algebra"),
       case .map(let entries) = value,
       let include = entries["__include"]?.stringValue,
       let spelling = RimeAuxiliarySpelling.allCases.first(where: { $0.includePath == include }) {
      auxiliarySpelling = spelling
      return
    }
    guard let effective = try? engine.schemaValue("speller/algebra", schemaID: "radical_pinyin") else { return }
    auxiliarySpelling = RimeAuxiliarySpelling.allCases.first {
      (try? engine.schemaValue($0.algebraKey, schemaID: "radical_pinyin")) == effective
    } ?? .fullPinyin
  }

  func setAuxiliarySpelling(_ spelling: RimeAuxiliarySpelling) {
    guard let profileID = activeProfileID, !profileID.isEmpty else {
      settingsFooter = .failed("请先部署并启用一个 Rime 配置。")
      return
    }
    auxiliarySpelling = spelling
    enqueueSettingsWrite(.auxiliarySpelling(spelling))
  }

  func updatePreferences(_ transform: (inout RimeKeyboardPreferences) -> Void) {
    guard let store = preferencesStore else {
      errorMessage = "拿不到 App Group，键盘设置无法共享给键盘。"
      return
    }
    var preferences = store.value
    transform(&preferences)
    store.value = preferences
    keyboardPreferences = preferences
  }

  func setAuxiliaryPrefix(_ value: String) {
    guard let prefix = RimeKeyboardPreferences.normalizedAuxiliaryPrefix(value) else { return }
    guard let profileID = activeProfileID, !profileID.isEmpty else {
      errorMessage = "请先部署并启用一个 Rime 配置。"
      settingsFooter = .failed("请先部署并启用一个 Rime 配置。")
      return
    }
    guard let schemaID = settingsSchemaID ?? (try? engine.schemaIDs().first) else {
      errorMessage = "还没有可配置辅码键的 Rime 方案。"
      settingsFooter = .failed("还没有可配置辅码键的 Rime 方案。")
      return
    }
    guard preferencesStore != nil else {
      errorMessage = "拿不到 App Group，辅码设置无法共享给键盘。"
      settingsFooter = .failed("拿不到 App Group，辅码设置无法共享给键盘。")
      return
    }
    updatePreferences { $0.auxiliaryPrefix = prefix }
    enqueueSettingsWrite(.auxiliaryPrefix(schemaID: schemaID, prefix: prefix))
  }

  func resetPreferences() {
    preferencesStore?.reset()
    refreshPreferences()
  }
}
