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

  /// The presets, each marked with whether this profile actually ships the table it names. Importing
  /// a preset whose file is missing leaves the schema with no punctuation at all, so the screen has
  /// to say which ones are available instead of offering all three equally.
  var punctuationChoices: [(preset: RimePunctuationPreset, isAvailable: Bool)] {
    // The decision is the engine's now (RimePunctuation.choices): a preset whose table the profile does not
    // ship is offered as unavailable rather than as a trap.
    guard let source = activeProfileID.map({ workspace.profile($0).source }) else {
      // No profile at all: the same rule with nothing to look in, so only the preset that needs no table is
      // offered. Borrowing another directory here would have been a decision made by accident.
      return RimePunctuation.presets.map { ($0, $0.requiresFile == nil) }
    }
    return RimePunctuation.choices(inSource: source).map { ($0.preset, $0.isAvailable) }
  }

  var currentPunctuationPreset: String? {
    guard let id = settingsSchemaID else { return nil }
    let value = try? engine.schemaValue("punctuator/import_preset", schemaID: id)?.stringValue
    return value ?? nil
  }

  func setPunctuationPreset(_ preset: RimePunctuationPreset) async {
    guard let id = settingsSchemaID else { return }
    do {
      let patch = RimePatch(engine: engine, configID: id)
      _ = try patch.set(.string(preset.importPreset), at: "punctuator/import_preset")
      await deploy(profileID: activeProfileID ?? id)
    } catch {
      errorMessage = "写入标点设置失败：" + String(describing: error)
    }
  }

  // MARK: Key bindings

  func refreshKeyBindings() {
    guard let id = settingsSchemaID,
          let bindings = try? engine.schemaValue("key_binder/bindings", schemaID: id)?.listValue
    else {
      enabledKeyBindingOptions = []
      return
    }
    enabledKeyBindingOptions = RimeKeyBindings.enabledOptions(in: bindings)
  }

  func setKeyBindingOptions(_ enabled: [String]) async {
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
      errorMessage = "写入按键设置失败：" + String(describing: error)
    }
  }
}
