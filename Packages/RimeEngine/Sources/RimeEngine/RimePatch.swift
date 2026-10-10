import Foundation

// MARK: - Patch files

/// Every write the app makes goes through here: S2's rule is that only `<config>.custom.yaml`
/// patches are written, shipped sources are read-only, and a reset deletes the key.
///
/// The file is Arkey's own flat form — one `key/path: value` line per entry — because Rime's patch
/// semantics replace a map wholesale, so a write in the nested form deletes the siblings of the key it
/// names (measured; see docs/s2-results.md). librime's config API cannot address a key that contains a
/// slash, so this type owns both the writing and the reading.
public struct RimePatch {
  public let engine: RimeEngine
  /// The config being patched, e.g. "default" for `default.custom.yaml`, or a schema id.
  public let configID: String
  private let fileManager: FileManager

  public init(engine: RimeEngine, configID: String, fileManager: FileManager = .default) {
    self.engine = engine
    self.configID = configID
    self.fileManager = fileManager
  }

  /// The user's copy of this config, which is the patch file itself.
  public var patchConfigID: String { configID + ".custom" }

  public var patchFileURL: URL {
    URL(fileURLWithPath: engine.directories.userDataDir, isDirectory: true)
      .appendingPathComponent(configID + ".custom.yaml")
  }

  // MARK: Reading

  /// What the user has explicitly set, or nil when the key is inherited from the schema.
  public func userValue(_ key: String) throws -> RimeConfigValue? {
    try entries()[key]
  }

  /// What the deployed engine actually uses, patch included.
  public func effectiveValue(_ key: String, schemaID: String? = nil) throws -> RimeConfigValue? {
    if let schemaID {
      return try engine.withSchemaConfig(schemaID) { $0.value(key) }
    }
    return try engine.withConfig(configID) { $0.value(key) }
  }

  /// The leaf keys the user has set, as paths: `menu/page_size`, `style/ascii_punct`.
  public func userKeys() throws -> [String] {
    try entries().keys.sorted()
  }

  /// The patch as one flat table: key path to value, with no nested map in between.
  ///
  /// Measured, and it is why this is no longer written through librime's config API: a patch written
  /// as nested maps is applied by **replacing** the map it names, so
  /// `translator: {enable_completion: true}` deletes `translator/dictionary` and the schema loses its
  /// dictionary (see [docs/s2-results.md](../../../../docs/s2-results.md)). The same value written as
  /// one flat key merges at the leaf. librime cannot address a key that contains a slash — its path
  /// syntax splits on it — so the file is read back here and each value is parsed on its own.
  func entries() throws -> [String: RimeConfigValue] {
    guard fileManager.fileExists(atPath: patchFileURL.path) else { return [:] }
    let text = (try? String(contentsOf: patchFileURL, encoding: .utf8)) ?? ""
    if let flat = try? flatEntries(from: text) { return flat }
    return try nestedEntries()
  }

  /// Flat keys with flow values or indented block lists, including quoted path keys.
  /// Nested maps fall back to librime's reader rather than losing their entries.
  private func flatEntries(from text: String) throws -> [String: RimeConfigValue] {
    var entries: [String: RimeConfigValue] = [:]
    var sawPatch = false
    let lines = text.components(separatedBy: "\n")
    var index = 0
    while index < lines.count {
      let line = lines[index]
      index += 1
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      if !sawPatch {
        guard trimmed == "patch:" else { throw RimePatchError.notAFlatPatch }
        sawPatch = true
        continue
      }
      let body = line.hasPrefix("  ") && !line.hasPrefix("   ") ? String(line.dropFirst(2)) : nil
      guard let body, let separator = body.firstIndex(of: ":") else {
        throw RimePatchError.notAFlatPatch
      }
      let rawKey = String(body[..<separator])
      let key: String
      if rawKey.hasPrefix("\"") || rawKey.hasPrefix("'") {
        guard let decoded = try value(fromYAML: rawKey).stringValue else {
          throw RimePatchError.notAFlatPatch
        }
        key = decoded
      } else {
        key = rawKey
      }
      guard key.unicodeScalars.allSatisfy({ RimePatch.safeKeyScalars.contains($0) }) else {
        throw RimePatchError.notAFlatPatch
      }
      var yaml = String(body[body.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      // Hand-written flat patches often use block lists. Parse the value as a detached
      // YAML document so its slash-containing key is never interpreted as a config path.
      while index < lines.count {
        let next = lines[index]
        let trimmedNext = next.trimmingCharacters(in: .whitespaces)
        if trimmedNext.isEmpty || trimmedNext.hasPrefix("#") {
          index += 1
          continue
        }
        guard next.hasPrefix("   ") else { break }
        yaml += "\n" + next
        index += 1
      }
      let parsed = try value(fromYAML: yaml)
      if yaml.hasPrefix("\n"), case .map = parsed {
        throw RimePatchError.notAFlatPatch
      }
      entries[key] = parsed
    }
    guard sawPatch else { throw RimePatchError.notAFlatPatch }
    return entries
  }

  /// Reads a file librime wrote, or one the user dropped in by hand: nested maps, block lists,
  /// comments. The leaves come back as paths, which is the flat form this type writes.
  private func nestedEntries() throws -> [String: RimeConfigValue] {
    try engine.withUserConfig(patchConfigID) { config in
      var entries: [String: RimeConfigValue] = [:]
      // Unsupported flat syntax must fail closed: librime cannot address literal slash
      // keys through its path API, so falling back would silently lose those settings.
      guard !config.mapKeys("patch").contains(where: { $0.contains("/") }) else {
        throw RimePatchError.notAFlatPatch
      }
      for path in config.leafPaths("patch") {
        if let value = config.value("patch/" + path) { entries[path] = value }
      }
      return entries
    }
  }

  private func value(fromYAML text: String) throws -> RimeConfigValue {
    let config = try engine.configFromYAML("value: " + text + "\n")
    defer { config.close() }
    guard let value = config.value("value") else { throw RimePatchError.notAFlatPatch }
    return value
  }

  private func value(inYAML yaml: String, atKey key: String) throws -> RimeConfigValue {
    let config = try engine.configFromYAML(yaml)
    defer { config.close() }
    guard let value = config.value(key) else { throw RimePatchError.writeFailed(key) }
    return value
  }

  // MARK: Writing

  /// Sets one key, returning what changed so the probe log and the deploy screen can say so.
  @discardableResult
  public func set(_ value: RimeConfigValue, at key: String) throws -> RimeConfigChange {
    let before = try userValue(key)
    var table = try entries()
    table[key] = value
    try write(table)
    return RimeConfigChange(configID: configID, key: key, oldValue: before, newValue: value)
  }

  /// Updates the schema's auxiliary search key and accepted spelling alphabet in one patch write.
  /// Existing alphabet characters are kept because another translator may still use them.
  @discardableResult
  public func setAuxiliaryPrefix(_ prefix: String, alphabet: String) throws -> RimeConfigChange {
    guard let normalized = RimeKeyboardPreferences.normalizedAuxiliaryPrefix(prefix) else {
      throw RimePatchError.writeFailed("key_binder/search")
    }
    var table = try entries()
    let before = table["key_binder/search"]
    table["key_binder/search"] = .string(normalized)
    if !alphabet.contains(normalized) {
      table["speller/alphabet"] = .string(alphabet + normalized)
    }
    try write(table)
    return RimeConfigChange(configID: configID, key: "key_binder/search",
                            oldValue: before, newValue: .string(normalized))
  }

  /// Sets a whole list or map from a YAML fragment, which is what the list-valued settings need.
  @discardableResult
  public func setItem(fromYAML yaml: String, sourceKey: String, at key: String) throws -> RimeConfigChange {
    let before = try userValue(key)
    let value = try value(inYAML: yaml, atKey: sourceKey)
    var table = try entries()
    table[key] = value
    try write(table)
    return RimeConfigChange(configID: configID, key: key, oldValue: before, newValue: value)
  }

  /// Resetting a key deletes it from the patch, so the schema's own value comes back.
  ///
  /// Measured, and it is why the file is flat: Rime's patch semantics replace a map wholesale, so a patch
  /// that still says `menu: {}` erases `menu/page_size` even though the schema supplies it. In the nested
  /// form a reset therefore had to prune the ancestors it emptied; a flat entry **is** the leaf, so
  /// deleting it cannot take a sibling with it.
  @discardableResult
  public func remove(key: String) throws -> RimeConfigChange {
    let before = try userValue(key)
    var table = try entries()
    table.removeValue(forKey: key)
    try write(table)
    return RimeConfigChange(configID: configID, key: key, oldValue: before, newValue: nil)
  }

  /// Resetting a screen deletes the file.
  public func removeAll() throws {
    try write([:])
  }

  /// Writes the whole patch in the flat form. Values are emitted in flow style so that every entry
  /// stays on one line, which is both what `flatEntries` reads back and what keeps a diff readable.
  func write(_ table: [String: RimeConfigValue]) throws {
    guard !table.isEmpty else {
      // An empty patch is a file that says nothing, and deleting it is what "reset" means to a user.
      if fileManager.fileExists(atPath: patchFileURL.path) {
        try? fileManager.removeItem(at: patchFileURL)
      }
      return
    }
    var text = "# Arkey writes this file. One flat key per entry: Rime's patch semantics merge at the\n"
    text += "# leaf, while a nested map would replace the map it names (docs/s2-results.md).\n"
    text += "patch:\n"
    for key in table.keys.sorted() {
      text += "  " + RimePatch.flatKey(key) + ": " + RimePatch.yaml(table[key]!) + "\n"
    }
    try text.write(to: patchFileURL, atomically: true, encoding: .utf8)
  }

  /// The characters a flat key may use unquoted: paths and list indices, nothing a YAML scalar would
  /// have to escape. A key outside this set is quoted, and the reader then refuses the file rather
  /// than mis-splitting it.
  static let safeKeyScalars = CharacterSet(charactersIn:
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./@-+")

  static func flatKey(_ key: String) -> String {
    key.unicodeScalars.allSatisfy { safeKeyScalars.contains($0) } ? key : "\"" + escape(key) + "\""
  }

  static func yaml(_ value: RimeConfigValue) -> String {
    switch value {
    case .bool(let flag): return flag ? "true" : "false"
    case .int(let number): return String(number)
    case .double(let number): return String(number)
    case .string(let text): return "\"" + escape(text) + "\""
    case .list(let items): return "[" + items.map(yaml).joined(separator: ", ") + "]"
    case .map(let entries):
      return "{" + entries.keys.sorted()
        .map { flatKey($0) + ": " + yaml(entries[$0]!) }
        .joined(separator: ", ") + "}"
    }
  }

  static func escape(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\\": out += "\\\\"
      case "\"": out += "\\\""
      case "\n": out += "\\n"
      case "\t": out += "\\t"
      case "\r": out += "\\r"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\x%02X", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out
  }

  // MARK: Snapshots

  /// Copies the patch file aside before it is touched, so a deploy that breaks can be reverted in
  /// one action (S2 §5).
  @discardableResult
  public func snapshot(into directory: URL) throws -> URL? {
    guard fileManager.fileExists(atPath: patchFileURL.path) else { return nil }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let target = directory.appendingPathComponent(stamp, isDirectory: true)
    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    let destination = target.appendingPathComponent(patchFileURL.lastPathComponent)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: patchFileURL, to: destination)
    return destination
  }

  /// Puts a snapshot back and returns whether anything was restored.
  @discardableResult
  public func restore(from snapshot: URL) throws -> Bool {
    guard fileManager.fileExists(atPath: snapshot.path) else { return false }
    if fileManager.fileExists(atPath: patchFileURL.path) {
      try fileManager.removeItem(at: patchFileURL)
    }
    try fileManager.copyItem(at: snapshot, to: patchFileURL)
    return true
  }
}

public enum RimePatchError: Error, CustomStringConvertible, Sendable {
  case writeFailed(String)
  case schemaNotInProfile(String)
  case switchNotInSchema(String)
  case notAFlatPatch

  public var description: String {
    switch self {
    case .writeFailed(let key):
      return "librime refused to write the patch key '" + key + "'"
    case .schemaNotInProfile(let id):
      return "the active profile has no deployed schema '" + id + "'"
    case .switchNotInSchema(let name):
      return "the schema declares no switch named '" + name + "'"
    case .notAFlatPatch:
      return "the patch file is not in the flat form Arkey writes"
    }
  }
}

// MARK: - Fuzzy pinyin

/// One 模糊音 preset: a pair a learner confuses, and the algebra rules that make them equivalent.
///
/// S2 §2.1: the rules are *composed* with the schema's own algebra, never appended to the deployed
/// copy, so enabling a preset twice cannot accumulate duplicate rules.
public struct RimeFuzzyPinyinPreset: Sendable, Hashable, Identifiable {
  public let id: String
  /// The pair as a user reads it, e.g. "zh = z".
  public let displayName: String
  /// Rules generated for the schema's `speller/algebra`.
  public let rules: [String]

  public init(id: String, displayName: String, rules: [String]) {
    self.id = id
    self.displayName = displayName
    self.rules = rules
  }
}

public enum RimeFuzzyPinyin {
  /// The eleven presets S2 §3 lists, in the order a Chinese user expects to find them.
  public static let presets: [RimeFuzzyPinyinPreset] = [
    .init(id: "zh_z", displayName: "zh = z", rules: ["derive/^zh/z/", "derive/^z/zh/"]),
    .init(id: "ch_c", displayName: "ch = c", rules: ["derive/^ch/c/", "derive/^c/ch/"]),
    .init(id: "sh_s", displayName: "sh = s", rules: ["derive/^sh/s/", "derive/^s/sh/"]),
    .init(id: "n_l", displayName: "n = l", rules: ["derive/^n/l/", "derive/^l/n/"]),
    .init(id: "f_h", displayName: "f = h", rules: ["derive/^f/h/", "derive/^h/f/"]),
    .init(id: "r_l", displayName: "r = l", rules: ["derive/^r/l/", "derive/^l/r/"]),
    .init(id: "an_ang", displayName: "an = ang", rules: ["derive/an$/ang/", "derive/ang$/an/"]),
    .init(id: "en_eng", displayName: "en = eng", rules: ["derive/en$/eng/", "derive/eng$/en/"]),
    .init(id: "in_ing", displayName: "in = ing", rules: ["derive/in$/ing/", "derive/ing$/in/"]),
    .init(id: "ian_iang", displayName: "ian = iang", rules: ["derive/ian$/iang/", "derive/iang$/ian/"]),
    .init(id: "uan_uang", displayName: "uan = uang", rules: ["derive/uan$/uang/", "derive/uang$/uan/"]),
  ]

  public static func preset(id: String) -> RimeFuzzyPinyinPreset? {
    presets.first { $0.id == id }
  }

  /// The generated rules for the enabled presets, in preset order, each rule once.
  ///
  /// A preset that is unknown is ignored rather than guessed at: the caller reads the enabled set
  /// back from the file it wrote, so an unknown id means the file was edited by hand.
  public static func rules(for enabled: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for preset in presets where enabled.contains(preset.id) {
      for rule in preset.rules where seen.insert(rule).inserted {
        result.append(rule)
      }
    }
    return result
  }

  /// The algebra a schema should get: the generated rules in front of the schema's own, with the
  /// schema's rules preserved in place. Passing an empty set returns the base algebra unchanged,
  /// which is what makes disabling a preset idempotent.
  public static func compose(baseAlgebra: [String], enabled: [String]) -> [String] {
    let generated = rules(for: enabled)
    guard !generated.isEmpty else { return baseAlgebra }
    // A previously composed algebra may already carry generated rules; drop them first so the
    // result depends only on the enabled set and the base.
    let generatedSet = Set(presets.flatMap(\.rules))
    let base = baseAlgebra.filter { !generatedSet.contains($0) }
    return generated + base
  }

  /// The presets a deployed algebra currently carries, so a screen can show the state it wrote.
  public static func enabledPresets(in algebra: [String]) -> [String] {
    let present = Set(algebra)
    return presets.filter { preset in preset.rules.contains { present.contains($0) } }.map(\.id)
  }
}

// MARK: - Schema list

/// `default.custom.yaml`'s `schema_list`: which schemas the keyboard offers, in which order.
///
/// Rime replaces a list wholesale, so a reorder rewrites the whole list — read the effective one
/// first, then write that back reordered, which is what keeps a hand-edited entry alive (S2 §2.1).
public struct RimeSchemaListEditor {
  public let patch: RimePatch
  /// The schema ids the profile ships (`*.schema.yaml` in its sources). librime's own
  /// `schema_list` names only the enabled ones, so a schema the user turned off is invisible
  /// there — this is what "turn it back on" needs.
  public let installed: [String]
  private let engine: RimeEngine

  public init(engine: RimeEngine, installed: [String] = []) {
    self.engine = engine
    self.installed = installed
    self.patch = RimePatch(engine: engine, configID: "default")
  }

  /// Every schema the screen may offer: what the profile ships, plus anything a hand-edited
  /// `schema_list` already names.
  public func available() throws -> [String] {
    var ids = installed
    for id in try engine.schemaIDs() where !ids.contains(id) { ids.append(id) }
    return ids
  }

  /// The list the deployed engine uses, as schema ids.
  public func effective() throws -> [String] {
    guard let list = try patch.effectiveValue("schema_list")?.listValue else { return [] }
    return list.compactMap { entry in
      switch entry {
      case .string(let value): return value
      case .map(let map): return map["schema"]?.stringValue
      default: return nil
      }
    }
  }

  /// Writes the whole list back. `enabled` must be a reordering or a subset of `effective()`;
  /// a name that is not deployed is refused rather than written, because librime would accept it
  /// and then offer a schema that cannot load.
  @discardableResult
  public func write(_ ids: [String]) throws -> RimeConfigChange {
    let available = Set(try available())
    if !available.isEmpty {
      for id in ids where !available.contains(id) {
        throw RimePatchError.schemaNotInProfile(id)
      }
    }
    let value = RimeConfigValue.list(ids.map { .map(["schema": .string($0)]) })
    return try patch.set(value, at: "schema_list")
  }
}
