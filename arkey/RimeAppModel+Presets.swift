import Combine
import Foundation
import RimeEngine
import SwiftUI

/// Saves the selected punctuation preset and redeploys the active profile.
@MainActor
extension RimeAppModel {
  // MARK: Punctuation

  func setPunctuationPreset(_ preset: RimePunctuationPreset) async {
    configurationRevision += 1
    guard let id = settingsSchemaID else { return }
    do {
      let patch = RimePatch(engine: engine, configID: id)
      recordConfigChange(try patch.setPunctuationPreset(preset))
      await deploy(profileID: activeProfileID ?? id)
      await refreshSettings()
    } catch {
      errorMessage = RimeLocalization.message("Failed to save punctuation settings: \(String(describing: error))")
    }
  }
}
