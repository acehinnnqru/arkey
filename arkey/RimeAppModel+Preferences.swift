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

  func refreshPreferences() async {
    keyboardPreferences = preferencesStore?.value ?? .standard
    guard deployInFlight == nil else { return }
    let readID = UUID()
    preferencesReadID = readID
    let revision = configurationRevision
    let engine = self.engine
    let snapshot = await Task.detached(priority: .userInitiated) {
      RimeKeyboardSettingsSnapshot.load(engine: engine)
    }.value
    guard !Task.isCancelled, preferencesReadID == readID else { return }
    if configurationRevision != revision {
      await refreshPreferences()
      return
    }
    guard deployInFlight == nil else { return }
    auxiliarySpelling = snapshot.spelling
    if let prefix = snapshot.prefix { keyboardPreferences.auxiliaryPrefix = prefix }
    for intent in pendingSettingsWrites {
      switch intent {
      case .auxiliaryPrefix(_, let prefix): keyboardPreferences.auxiliaryPrefix = prefix
      case .auxiliarySpelling(let spelling): auxiliarySpelling = spelling
      default: break
      }
    }
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
    preferencesReadID = UUID()
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

  func resetPreferences() async {
    preferencesStore?.reset()
    await refreshPreferences()
  }
}
