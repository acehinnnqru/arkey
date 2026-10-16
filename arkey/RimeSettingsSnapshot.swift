import Foundation
import RimeEngine

/// Read engine configuration and profile files away from SwiftUI's navigation transaction.
struct RimeSettingsSnapshot: Sendable {
  let schemas: [String]
  let rows: [String]
  let order: [String]
  let descriptor: RimeSchemaDescriptor?
  let fuzzyPresets: [String]
  let punctuationChoices: [(preset: RimePunctuationPreset, isAvailable: Bool)]
  let punctuationPreset: String?
  let error: String?

  nonisolated static func load(engine: RimeEngine, source: URL?, punctuationSource: URL?) -> Self {
    if !engine.isRunning { _ = try? engine.start() }
    let schemas = (try? engine.schemaIDs()) ?? []
    let installed = source.map { RimeTreeClassifier.classify(root: $0).schemaIDs } ?? []
    let editor = RimeSchemaListEditor(engine: engine, installed: installed)
    let order = (try? editor.effective()) ?? []
    let offered = (try? editor.available()) ?? installed
    let current = try? engine.currentSchema()
    let schemaID = current.flatMap { $0.isEmpty ? nil : $0 } ?? schemas.first
    var descriptor: RimeSchemaDescriptor?
    var error: String?
    if let schemaID {
      do {
        descriptor = try RimeSettingsModel.describeSchema(schemaID, engine: engine)
      } catch let failure {
        error = String(describing: failure)
      }
    }
    let algebra = schemaID.flatMap {
      try? engine.schemaValue("speller/algebra", schemaID: $0)?.listValue
    } ?? []
    let punctuation = schemaID.flatMap {
      try? RimePunctuation.selectedPreset(schemaID: $0, engine: engine)
    }
    let choices = punctuationSource.map {
      RimePunctuation.choices(inSource: $0).map { (preset: $0.preset, isAvailable: $0.isAvailable) }
    } ?? RimePunctuation.presets.map { (preset: $0, isAvailable: $0.requiresFile == nil) }
    return Self(schemas: schemas, rows: offered + order.filter { !offered.contains($0) },
                order: order, descriptor: descriptor,
                fuzzyPresets: RimeFuzzyPinyin.enabledPresets(in: algebra.compactMap(\.stringValue)),
                punctuationChoices: choices, punctuationPreset: punctuation, error: error)
  }
}

struct RimeKeyboardSettingsSnapshot: Sendable {
  let prefix: String?
  let spelling: RimeAuxiliarySpelling

  nonisolated static func load(engine: RimeEngine) -> Self {
    if !engine.isRunning { _ = try? engine.start() }
    let current = try? engine.currentSchema()
    let schemaID = current.flatMap { $0.isEmpty ? nil : $0 } ?? (try? engine.schemaIDs().first)
    let prefix = schemaID.flatMap {
      try? engine.schemaValue("key_binder/search", schemaID: $0)?.stringValue
    }.flatMap(RimeKeyboardPreferences.normalizedAuxiliaryPrefix)
    let patch = RimePatch(engine: engine, configID: "radical_pinyin")
    if let value = try? patch.userValue("speller/algebra"),
       case .map(let entries) = value,
       let include = entries["__include"]?.stringValue,
       let spelling = RimeAuxiliarySpelling.allCases.first(where: { $0.includePath == include }) {
      return Self(prefix: prefix, spelling: spelling)
    }
    let effective = try? engine.schemaValue("speller/algebra", schemaID: "radical_pinyin")
    let spelling = effective.flatMap { effective in
      RimeAuxiliarySpelling.allCases.first {
        (try? engine.schemaValue($0.algebraKey, schemaID: "radical_pinyin")) == effective
      }
    } ?? .fullPinyin
    return Self(prefix: prefix, spelling: spelling)
  }
}
