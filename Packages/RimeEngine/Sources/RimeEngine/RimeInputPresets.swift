import Foundation

// MARK: - Punctuation

/// S2 §3's punctuation row: "the app exposes the choice, not the tables".
///
/// A table may expose a legacy `punctuator` section or a modern root `symbols` section.
/// The selected file's structure determines the patch syntax. Width and ASCII punctuation
/// remain schema switch states rather than table choices.
public struct RimePunctuationPreset: Sendable, Hashable, Identifiable {
  public let id: String
  private let displayNameMessage: RimeLocalizedMessage
  public var displayName: String { displayNameMessage.text }
  /// The config identifier used by a legacy import or a modern symbols include.
  public let importPreset: String
  private let noteMessage: RimeLocalizedMessage
  public var note: String { noteMessage.text }
  /// True when the schema actually ships the file this preset names. A preset whose table is not in
  /// the profile is offered only as a warning, because importing a preset that is not there leaves the
  /// schema with no punctuation at all.
  public let requiresFile: String?

  public init(id: String, displayName: RimeLocalizedMessage, importPreset: String, note: RimeLocalizedMessage,
              requiresFile: String? = nil) {
    self.id = id
    self.displayNameMessage = displayName
    self.importPreset = importPreset
    self.noteMessage = note
    self.requiresFile = requiresFile
  }
}

public enum RimePunctuation {
  public static var presets: [RimePunctuationPreset] { [
    .init(id: "default", displayName: RimeLocalization.message("Schema default"), importPreset: "default",
          note: RimeLocalization.message("Restore the active schema's punctuation settings.")),
    .init(id: "symbols", displayName: RimeLocalization.message("Default symbol table"), importPreset: "symbols",
          note: RimeLocalization.message("The profile’s symbols.yaml."), requiresFile: "symbols.yaml"),
    .init(id: "symbols_v", displayName: RimeLocalization.message("Extended symbol table"), importPreset: "symbols_v",
          note: RimeLocalization.message("Rime Ice’s symbols_v.yaml: more punctuation and vertical symbols."),
          requiresFile: "symbols_v.yaml"),
  ] }

  public static func preset(id: String) -> RimePunctuationPreset? {
    presets.first { $0.id == id }
  }

  /// Modern symbol tables expose `symbols` at the root, while legacy presets expose
  /// `punctuator`. Importing the former with import_preset makes the entire schema fail to compile.
  static func usesRootSymbols(_ preset: RimePunctuationPreset, engine: RimeEngine) throws -> Bool {
    guard let file = preset.requiresFile else { return false }
    let url = URL(fileURLWithPath: engine.directories.sharedDataDir).appendingPathComponent(file)
    let config = try engine.configFromYAML(String(contentsOf: url, encoding: .utf8))
    defer { config.close() }
    if config.value("punctuator")?.mapValue != nil { return false }
    guard config.value("symbols")?.mapValue != nil else {
      throw RimeEngineError.configValueMissing(file + ": punctuator or symbols")
    }
    return true
  }

  public static func selectedPreset(schemaID: String, engine: RimeEngine) throws -> String? {
    let patch = RimePatch(engine: engine, configID: schemaID)
    if let include = try patch.userValue("punctuator/symbols")?.mapValue?["__include"]?.stringValue,
       let preset = presets.first(where: { include == $0.importPreset + ":/symbols" }) {
      return preset.importPreset
    }
    return try patch.userValue("punctuator/import_preset")?.stringValue
      ?? engine.schemaValue("punctuator/import_preset", schemaID: schemaID)?.stringValue
      ?? "default"
  }

  /// Migrate only a legacy import that demonstrably points at a modern symbol table.
  /// Keep an exact copy of each affected patch before changing the syntax.
  public static func repairLegacySymbolImports(schemaIDs: [String], engine: RimeEngine,
                                                backupDirectory: URL) throws -> [RimeConfigChange] {
    var changes: [RimeConfigChange] = []
    for id in schemaIDs {
      let patch = RimePatch(engine: engine, configID: id)
      guard let name = try patch.userValue("punctuator/import_preset")?.stringValue,
            let preset = presets.first(where: { $0.importPreset == name }),
            try usesRootSymbols(preset, engine: engine) else { continue }
      try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: patch.patchFileURL,
                                      to: backupDirectory.appendingPathComponent(patch.patchFileURL.lastPathComponent))
      changes.append(try patch.setPunctuationPreset(preset))
    }
    return changes
  }

  /// One preset and whether the profile can actually offer it.
  public struct Choice: Sendable, Hashable {
    public let preset: RimePunctuationPreset
    public let isAvailable: Bool

    public init(preset: RimePunctuationPreset, isAvailable: Bool) {
      self.preset = preset
      self.isAvailable = isAvailable
    }
  }

  /// Which presets a profile's source directory can back, which is the decision the 标点 screen shows.
  ///
  /// It lived in the app, where nothing could test it — and it is the difference between a screen that warns
  /// and one that leaves the schema with no punctuation at all: importing a table the profile does not ship is
  /// worse than not offering it.
  public static func choices(inSource source: URL,
                             fileManager: FileManager = .default) -> [Choice] {
    presets.map { preset in
      guard let required = preset.requiresFile else {
        return Choice(preset: preset, isAvailable: true)
      }
      let table = source.appendingPathComponent(required)
      return Choice(preset: preset, isAvailable: fileManager.fileExists(atPath: table.path))
    }
  }
}

extension RimePatch {
  /// Write both related paths atomically, preserving the schema's own width and punctuation maps.
  @discardableResult
  public func setPunctuationPreset(_ preset: RimePunctuationPreset) throws -> RimeConfigChange {
    let rootSymbols = try RimePunctuation.usesRootSymbols(preset, engine: engine)
    var table = try entries()
    let before = table["punctuator/import_preset"]
    table.removeValue(forKey: "punctuator/import_preset")
    // Only remove a symbols override that this picker owns.
    if let include = table["punctuator/symbols"]?.mapValue?["__include"]?.stringValue,
       RimePunctuation.presets.contains(where: { include == $0.importPreset + ":/symbols" }) {
      table.removeValue(forKey: "punctuator/symbols")
    }
    if rootSymbols {
      table["punctuator/symbols"] = .map(["__include": .string(preset.importPreset + ":/symbols")])
    } else if preset.id != "default" {
      table["punctuator/import_preset"] = .string(preset.importPreset)
    }
    try write(table)
    return RimeConfigChange(configID: configID, key: "punctuator/import_preset",
                            oldValue: before, newValue: table["punctuator/import_preset"])
  }
}
