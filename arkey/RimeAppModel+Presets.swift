import Combine
import Foundation
import RimeEngine
import SwiftUI

/// S2 §3's last two rows: which punctuation table the schema imports, and which curated key bindings
/// are on. Both are patches, both are followed by a deploy, and both are *composed* rather than
/// appended — the same rule 模糊音 follows, for the same reason.
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

  // MARK: Key bindings

  func refreshKeyBindings() async {
    let engine = self.engine
    let fallback = schemas.first
    let revision = configurationRevision
    let enabled = await Task.detached(priority: .userInitiated) {
      let current = try? engine.currentSchema()
      guard let id = current.flatMap({ $0.isEmpty ? nil : $0 }) ?? fallback,
            let bindings = try? engine.schemaValue("key_binder/bindings", schemaID: id)?.listValue
      else { return [String]() }
      return RimeKeyBindings.enabledOptions(in: bindings)
    }.value
    guard !Task.isCancelled else { return }
    if revision != configurationRevision {
      await refreshKeyBindings()
      return
    }
    enabledKeyBindingOptions = enabled
  }

  func setKeyBindingOptions(_ enabled: [String]) async {
    configurationRevision += 1
    guard let id = settingsSchemaID else { return }
    do {
      // The base is the *deployed* list, so a previous composition is replaced rather than stacked.
      let base = (try engine.schemaValue("key_binder/bindings", schemaID: id)?.listValue ?? [])
      let composed = RimeKeyBindings.compose(base: base, enabled: enabled)
      let patch = RimePatch(engine: engine, configID: id)
      if composed.isEmpty {
        _ = try patch.remove(key: "key_binder/bindings")
      } else {
        _ = try patch.set(.list(composed), at: "key_binder/bindings")
      }
      enabledKeyBindingOptions = enabled
      await deploy(profileID: activeProfileID ?? id)
    } catch {
      errorMessage = RimeLocalization.message("Failed to save key settings: \(String(describing: error))")
    }
  }
}
