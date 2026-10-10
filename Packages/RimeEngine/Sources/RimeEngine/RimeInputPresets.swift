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

// MARK: - Key bindings

/// S2 §3's 按键 row: "a curated set (page keys `-`/`=`, select keys, commit keys), not a free editor".
///
/// Like 模糊音, the list is *composed*: the enabled options' bindings are prepended to the schema's own
/// and any binding a previous composition generated is filtered out first, so toggling twice cannot
/// accumulate duplicates and disabling one removes only its own entries.
public struct RimeKeyBindingOption: Sendable, Hashable, Identifiable {
  public let id: String
  public let displayName: String
  public let note: String
  public let bindings: [RimeConfigValue]

  public init(id: String, displayName: String, note: String, bindings: [RimeConfigValue]) {
    self.id = id
    self.displayName = displayName
    self.note = note
    self.bindings = bindings
  }

  /// The identity of one binding, for filtering: the three fields a Rime binding is made of.
  static func identity(of value: RimeConfigValue) -> String? {
    guard let map = value.mapValue,
          let when = map["when"]?.stringValue,
          let accept = map["accept"]?.stringValue,
          let send = map["send"]?.stringValue else { return nil }
    return when + "|" + accept + "|" + send
  }

  static func binding(_ when: String, _ accept: String, _ send: String) -> RimeConfigValue {
    .map(["when": .string(when), "accept": .string(accept), "send": .string(send)])
  }
}

public enum RimeKeyBindings {
  public static var options: [RimeKeyBindingOption] { [
    .init(id: "page_minus_equal", displayName: RimeLocalization.text("Paging: - and ="),
          note: RimeLocalization.text("Common Rime convention: minus for previous page, equals for next page."),
          bindings: [
            RimeKeyBindingOption.binding("paging", "-", "Page_Up"),
            RimeKeyBindingOption.binding("has_menu", "=", "Page_Down"),
          ]),
    .init(id: "page_bracket", displayName: RimeLocalization.text("Paging: [ and ]"),
          note: RimeLocalization.text("Use brackets for paging, keeping minus and equals available."),
          bindings: [
            RimeKeyBindingOption.binding("paging", "bracketleft", "Page_Up"),
            RimeKeyBindingOption.binding("has_menu", "bracketright", "Page_Down"),
          ]),
    .init(id: "select_semicolon_quote", displayName: RimeLocalization.text("Selection: ; and '"),
          note: RimeLocalization.text("Semicolon selects the second candidate; apostrophe selects the third."),
          bindings: [
            RimeKeyBindingOption.binding("has_menu", "semicolon", "2"),
            RimeKeyBindingOption.binding("has_menu", "apostrophe", "3"),
          ]),
    .init(id: "word_selection", displayName: RimeLocalization.text("Character selection: [ and ]"),
          note: RimeLocalization.text("Brackets select the first and last characters of a word when they do not conflict with paging."),
          bindings: [
            RimeKeyBindingOption.binding("has_menu", "bracketleft", "commit_comment"),
            RimeKeyBindingOption.binding("has_menu", "bracketright", "commit_raw_input"),
          ]),
  ] }

  public static func option(id: String) -> RimeKeyBindingOption? {
    options.first { $0.id == id }
  }

  /// The bindings a schema should get: the enabled options' entries in front of everything else.
  ///
  /// The rule is deliberately blunt, because the alternative cannot be made idempotent: a list that
  /// contains @B@-@B@ → Page_Up cannot say whether the schema declared it or a previous composition generated
  /// it, so **the catalogue owns every binding it can generate**. An option that is off removes its own
  /// entries even if the schema happened to declare the same three fields — which is what "off" means —
  /// and an option that is on contributes them exactly once however many times this runs.
  public static func compose(base: [RimeConfigValue], enabled: [String]) -> [RimeConfigValue] {
    let generated = Set(options.flatMap { $0.bindings.compactMap(RimeKeyBindingOption.identity) })
    var composed: [RimeConfigValue] = []
    var seen = Set<String>()
    for id in enabled {
      guard let option = option(id: id) else { continue }
      for binding in option.bindings {
        guard let identity = RimeKeyBindingOption.identity(of: binding) else { continue }
        if seen.insert(identity).inserted {
          composed.append(binding)
        }
      }
    }
    let remainder = base.filter { value in
      guard let identity = RimeKeyBindingOption.identity(of: value) else { return true }
      return !generated.contains(identity)
    }
    return composed + remainder
  }

  /// Which options a deployed bindings list currently carries, so the screen shows the state it wrote.
  public static func enabledOptions(in bindings: [RimeConfigValue]) -> [String] {
    let present = Set(bindings.compactMap(RimeKeyBindingOption.identity))
    return options.filter { option in
      option.bindings.contains { binding in
        RimeKeyBindingOption.identity(of: binding).map(present.contains) ?? false
      }
    }.map(\.id)
  }
}
