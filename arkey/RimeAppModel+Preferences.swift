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
      settingsFooter = .failed(RimeLocalization.message("Deploy and activate a Rime profile first."))
      return
    }
    auxiliarySpelling = spelling
    enqueueSettingsWrite(.auxiliarySpelling(spelling))
  }

  func updatePreferences(_ transform: (inout RimeKeyboardPreferences) -> Void) {
    preferencesReadID = UUID()
    guard let store = preferencesStore else {
      errorMessage = RimeLocalization.message("App Group is unavailable; keyboard settings cannot be shared with the keyboard.")
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
      errorMessage = RimeLocalization.message("Deploy and activate a Rime profile first.")
      settingsFooter = .failed(RimeLocalization.message("Deploy and activate a Rime profile first."))
      return
    }
    guard let schemaID = settingsSchemaID ?? (try? engine.schemaIDs().first) else {
      errorMessage = RimeLocalization.message("No Rime scheme is available to configure the auxiliary key.")
      settingsFooter = .failed(RimeLocalization.message("No Rime scheme is available to configure the auxiliary key."))
      return
    }
    guard preferencesStore != nil else {
      errorMessage = RimeLocalization.message("App Group is unavailable; auxiliary settings cannot be shared with the keyboard.")
      settingsFooter = .failed(RimeLocalization.message("App Group is unavailable; auxiliary settings cannot be shared with the keyboard."))
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
