import Foundation

// MARK: - Issues

public struct RimeValidationIssue: Sendable, Hashable, CustomStringConvertible {
  public enum Severity: String, Sendable {
    case warning
    case error
  }

  public let severity: Severity
  /// The file or key the issue is about, relative to the profile source where it is a file.
  public let path: String
  public let message: String

  public init(severity: Severity, path: String, message: String) {
    self.severity = severity
    self.path = path
    self.message = message
  }

  public var description: String { severity.rawValue + ": " + path + ": " + message }

  public static func error(_ path: String, _ message: String) -> RimeValidationIssue {
    RimeValidationIssue(severity: .error, path: path, message: message)
  }

  public static func warning(_ path: String, _ message: String) -> RimeValidationIssue {
    RimeValidationIssue(severity: .warning, path: path, message: message)
  }
}

public struct RimeValidationResult: Sendable {
  public let issues: [RimeValidationIssue]
  /// The schema ids the config declares, in the order they are listed.
  public let schemaIDs: [String]
  public let fileCount: Int
  public let sourceBytes: Int

  public init(issues: [RimeValidationIssue], schemaIDs: [String], fileCount: Int, sourceBytes: Int) {
    self.issues = issues
    self.schemaIDs = schemaIDs
    self.fileCount = fileCount
    self.sourceBytes = sourceBytes
  }

  public var errors: [RimeValidationIssue] { issues.filter { $0.severity == .error } }
  public var warnings: [RimeValidationIssue] { issues.filter { $0.severity == .warning } }
  public var isAcceptable: Bool { errors.isEmpty }

  public var summary: String {
    if issues.isEmpty { return "no problems found" }
    return issues.map(\.description).joined(separator: "; ")
  }
}

public struct RimeValidationBudgets: Sendable {
  public var maxSourceBytes: Int
  public var maxFileCount: Int
  /// The disk precheck: a deploy produces tables larger than its sources. S1 §5.4 uses 3x.
  public var buildSizeMultiplier: Int

  public init(maxSourceBytes: Int = 2 << 30, maxFileCount: Int = 200_000, buildSizeMultiplier: Int = 3) {
    self.maxSourceBytes = maxSourceBytes
    self.maxFileCount = maxFileCount
    self.buildSizeMultiplier = buildSizeMultiplier
  }

  public static let standard = RimeValidationBudgets()
}

// MARK: - Validation

/// Answers S1 §5.4's question — "will librime load this?" — with librime's own parser.
///
/// A file Rime accepts is compatible by definition, so every YAML file here goes through
/// \`config_load_string\` rather than through a parser of ours. What our own code adds is the part
/// librime does not do at import time: resolving the references a schema makes to files it expects
/// beside it, and saying which of them are missing before the keyboard discovers it.
public enum RimeConfigValidation {
  public static func validate(source: URL,
                              engine: RimeEngine,
                              budgets: RimeValidationBudgets = .standard,
                              fileManager: FileManager = .default) -> RimeValidationResult {
    var issues: [RimeValidationIssue] = []
    let files = RimeFileScan.scan(root: source, fileManager: fileManager)

    // 6. Budget, checked first so an absurd tree is refused before it is parsed.
    if files.totalBytes > budgets.maxSourceBytes {
      issues.append(.error(".",
                           "the config is " + RimeFileScan.megabytes(files.totalBytes)
                             + " MB of sources, above the " + RimeFileScan.megabytes(budgets.maxSourceBytes)
                             + " MB limit"))
    }
    if files.paths.count > budgets.maxFileCount {
      issues.append(.error(".", "the config holds " + String(files.paths.count) + " files, above the limit of "
                           + String(budgets.maxFileCount)))
    }
    checkFreeSpace(source: source, bytes: files.totalBytes, multiplier: budgets.buildSizeMultiplier,
                   issues: &issues)

    // 5. Files librime reads must be UTF-8: its YAML reader is not forgiving about it.
    for path in files.textPaths where !RimeFileScan.isUTF8(source.appendingPathComponent(path)) {
      issues.append(.error(path, "the file is not UTF-8, and Rime's reader will not accept it"))
    }

    // 1. default.yaml parses, and schema_list is a non-empty list.
    guard files.paths.contains("default.yaml") else {
      issues.append(.error("default.yaml", "the config root has no default.yaml"))
      return RimeValidationResult(issues: issues, schemaIDs: [], fileCount: files.paths.count,
                                  sourceBytes: files.totalBytes)
    }
    let defaultText = RimeFileScan.text(source.appendingPathComponent("default.yaml"))
    guard let defaultConfig = parse(defaultText, path: "default.yaml", engine: engine, issues: &issues) else {
      return RimeValidationResult(issues: issues, schemaIDs: [], fileCount: files.paths.count,
                                  sourceBytes: files.totalBytes)
    }
    defer { defaultConfig.close() }

    let schemaIDs = schemaList(in: defaultConfig)
    if schemaIDs.isEmpty {
      issues.append(.error("default.yaml", "schema_list is missing or empty: librime would deploy a config "
                         + "with no schema to type with"))
    }

    // 2 and 3. Every listed schema exists, and names a dictionary that does.
    //
    // A dictionary is checked once however many schemas use it: rime-ice's nine schemas share `rime_ice`, so
    // its broken imported tables were reported once per schema — forty-five identical lines on a device
    // screen where five files are missing (round 190). The schema's *own* checks stay per schema.
    var checkedDictionaries: Set<String> = []
    for id in schemaIDs {
      let schemaPath = id + ".schema.yaml"
      guard files.paths.contains(schemaPath) else {
        issues.append(.error(schemaPath, "schema_list names '" + id + "' but the file is not in the config"))
        continue
      }
      validateSchema(path: schemaPath, id: id, files: files, source: source, engine: engine,
                     issues: &issues, checkedDictionaries: &checkedDictionaries)
    }

    // A schema in the tree that schema_list does not name is worth saying out loud: it is deployed
    // but unreachable.
    for path in files.paths where path.hasSuffix(".schema.yaml") {
      let id = String(path.dropLast(".schema.yaml".count))
      if !schemaIDs.contains(id) {
        issues.append(.warning(path, "the schema is present but schema_list does not list it, so it will "
                           + "not be reachable from the keyboard"))
      }
    }

    // 4. References a schema makes to files beside it.
    for id in schemaIDs {
      let schemaPath = id + ".schema.yaml"
      guard files.paths.contains(schemaPath) else { continue }
      let text = RimeFileScan.text(source.appendingPathComponent(schemaPath))
      guard let config = parse(text, path: schemaPath, engine: engine, issues: &issues) else { continue }
      defer { config.close() }
      checkReferences(config: config, path: schemaPath, files: files, source: source, issues: &issues)
    }

    return RimeValidationResult(issues: issues, schemaIDs: schemaIDs, fileCount: files.paths.count,
                                sourceBytes: files.totalBytes)
  }

  // MARK: Schema checks

  private static func validateSchema(path: String, id: String, files: RimeFileScan.Result, source: URL,
                                     engine: RimeEngine, issues: inout [RimeValidationIssue],
                                     checkedDictionaries: inout Set<String>) {
    let text = RimeFileScan.text(source.appendingPathComponent(path))
    guard let config = parse(text, path: path, engine: engine, issues: &issues) else { return }
    defer { config.close() }

    let dictionary = config.string("translator/dictionary")
    if let dictionary, !dictionary.isEmpty {
      let dictionaryPath = resolve(dictionary, suffix: ".dict.yaml", files: files)
      if dictionaryPath == nil {
        issues.append(.error(dictionary + ".dict.yaml",
                             "the schema's translator names the dictionary '" + dictionary
                               + "', which is not in the config"))
      } else if checkedDictionaries.insert(dictionaryPath ?? "").inserted {
        checkImportedTables(dictionaryPath: dictionaryPath ?? "", files: files, source: source,
                            engine: engine, issues: &issues)
      }
    } else if files.paths.contains(where: { $0.hasSuffix(".dict.yaml") }) == false {
      issues.append(.error(path, "the schema has no translator/dictionary and the config holds no "
                         + "*.dict.yaml, so it would produce no candidates"))
    }

    // A schema with no switches still works; one with no engine does not.
    if config.value("engine") == nil {
      issues.append(.error(path, "the schema declares no engine: librime has no processors or translators to run"))
    } else if config.value("engine/translators") == nil {
      issues.append(.warning(path, "the schema's engine declares no translators"))
    }
  }

  private static func checkImportedTables(dictionaryPath: String, files: RimeFileScan.Result, source: URL,
                                          engine: RimeEngine, issues: inout [RimeValidationIssue]) {
    let text = RimeFileScan.text(source.appendingPathComponent(dictionaryPath))
    guard let config = parse(text, path: dictionaryPath, engine: engine, issues: &issues) else { return }
    defer { config.close() }

    guard let tables = config.value("import_tables")?.listValue else { return }
    for entry in tables {
      let name: String?
      switch entry {
      case .string(let value): name = value
      case .map(let map): name = map["table"]?.stringValue
      default: name = nil
      }
      guard let name, !name.isEmpty else { continue }
      if resolve(name, suffix: ".dict.yaml", files: files) == nil {
        issues.append(.error(name + ".dict.yaml",
                             "imported by " + dictionaryPath + " but not present in the config"))
      }
    }
  }

  // MARK: References

  private static func checkReferences(config: RimeConfigRef, path: String, files: RimeFileScan.Result,
                                      source: URL, issues: inout [RimeValidationIssue]) {
    let entries = flatten(config: config, prefix: "", depth: 0)

    for (key, value) in entries {
      guard let text = value.stringValue, !text.isEmpty else { continue }

      // librime-lua: a processor, segmentor, translator or filter names its script in the value,
      // as "lua_filter@*corrector", which is lua/corrector.lua. The leading "*" is librime-lua's
      // own marker on the plugin name, not part of the file name.
      let parts = text.split(separator: "@", omittingEmptySubsequences: false)
      if parts.count == 2, parts[0].hasPrefix("lua_") {
        let raw = String(parts[1])
        let name = raw.hasPrefix("*") ? String(raw.dropFirst()) : raw
        if !name.isEmpty, !files.paths.contains("lua/" + name + ".lua") {
          issues.append(.error("lua/" + name + ".lua",
                               "the schema's " + key + " runs this script, and the config does not contain it: "
                                 + "activating the schema would silently skip it"))
        }
      }

      if key.hasSuffix("opencc_config") {
        if !files.paths.contains("opencc/" + text) {
          issues.append(.warning("opencc/" + text,
                                 "missing, so the conversion it configures will not happen "
                                   + "(繁简转换将不可用)"))
        }
      }

      if key.hasSuffix("import_preset"), text.hasSuffix(".yaml") {
        if !files.paths.contains(text) {
          issues.append(.warning(text, "imported by " + key + " but not present in the config"))
        }
      }

      if text == "essay.txt" || text.hasSuffix(".gram") || text.hasSuffix(".db") {
        if !files.paths.contains(text) {
          issues.append(.warning(text, "named by " + key + " but not present: the feature it feeds stays off"))
        }
      }
    }

    // octagram: the grammar model is <language>.gram beside the schema.
    if let language = config.string("grammar/language"), !language.isEmpty {
      if !files.paths.contains(language + ".gram") {
        issues.append(.warning(language + ".gram",
                               "the schema declares a grammar for '" + language + "', and the model is not "
                                 + "here: grammar re-ranking stays off (it is a large, separate download)"))
      }
    }
  }

  // MARK: Helpers

  static func parse(_ text: String?, path: String, engine: RimeEngine,
                    issues: inout [RimeValidationIssue]) -> RimeConfigRef? {
    guard let text, !text.isEmpty else {
      issues.append(.error(path, "the file is empty or unreadable"))
      return nil
    }
    do {
      return try engine.configFromYAML(text)
    } catch {
      issues.append(.error(path, "librime refused the file: " + String(describing: error)))
      return nil
    }
  }

  static func schemaList(in config: RimeConfigRef) -> [String] {
    guard let entries = config.value("schema_list")?.listValue else { return [] }
    return entries.compactMap { entry in
      switch entry {
      case .string(let value): return value
      case .map(let map): return map["schema"]?.stringValue
      default: return nil
      }
    }
  }

  /// Rime's own shorthand: a dictionary is named without its extension and lives at the config root,
  /// and an entry that already carries the extension is taken as written.
  static func resolve(_ name: String, suffix: String, files: RimeFileScan.Result) -> String? {
    let candidates = [name, name + suffix, name + ".yaml"]
    for candidate in candidates where files.paths.contains(candidate) {
      return candidate
    }
    // A schema may name a dictionary in a subdirectory without the extension.
    let suffixed = name + suffix
    return files.paths.first { $0.hasSuffix(suffix) && ($0 == suffixed || $0.hasSuffix("/" + suffixed)) }
  }

  /// Every scalar in the config with its full key path, so a reference can be found wherever a
  /// schema chose to put it. Depth-capped: schema configs are shallow, and a pathological one must
  /// not turn validation into a hang.
  static func flatten(config: RimeConfigRef, prefix: String, depth: Int) -> [(String, RimeConfigValue)] {
    guard depth < 6, let root = config.value(prefix) else { return [] }
    switch root {
    case .map(let entries):
      var result: [(String, RimeConfigValue)] = []
      for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
        let path = prefix.isEmpty ? key : prefix + "/" + key
        switch value {
        case .map, .list:
          result.append(contentsOf: flatten(config: config, prefix: path, depth: depth + 1))
        default:
          result.append((path, value))
        }
      }
      return result
    case .list(let items):
      var result: [(String, RimeConfigValue)] = []
      for (index, value) in items.enumerated() {
        let path = prefix + "/@" + String(index)
        switch value {
        case .map, .list:
          result.append(contentsOf: flatten(config: config, prefix: path, depth: depth + 1))
        default:
          result.append((path, value))
        }
      }
      return result
    default:
      return [(prefix, root)]
    }
  }

  private static func checkFreeSpace(source: URL, bytes: Int, multiplier: Int,
                                     issues: inout [RimeValidationIssue]) {
    guard let values = try? source.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let available = values.volumeAvailableCapacityForImportantUsage else { return }
    let needed = bytes * multiplier
    if available < needed {
      issues.append(.error(".", "the deploy needs about " + RimeFileScan.megabytes(needed)
                           + " MB free and the volume has " + RimeFileScan.megabytes(Int(available)) + " MB"))
    }
  }
}

// MARK: - File scan

/// One walk of the tree, shared by every check: the alternative is five walks of a 50 MB config.
public enum RimeFileScan {
  public struct Result: Sendable {
    public var paths: [String]
    public var bytes: [String: Int]
    public var totalBytes: Int

    public var textPaths: [String] {
      paths.filter { path in
        let lower = path.lowercased()
        return lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") || lower.hasSuffix(".txt")
          || lower.hasSuffix(".lua") || lower.hasSuffix(".json")
      }
    }
  }

  public static func scan(root: URL, fileManager: FileManager = .default) -> Result {
    var result = Result(paths: [], bytes: [:], totalBytes: 0)
    guard let enumerator = fileManager.enumerator(at: root,
                                                  includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                  options: [.skipsHiddenFiles]) else { return result }
    let rootPath = root.standardizedFileURL.path
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values?.isRegularFile == true else { continue }
      let path = url.standardizedFileURL.path
      let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
      let size = values?.fileSize ?? 0
      result.paths.append(relative)
      result.bytes[relative] = size
      result.totalBytes += size
    }
    result.paths.sort()
    return result
  }

  public static func text(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func isUTF8(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url) else { return false }
    // A BOM is legal UTF-8; anything that decodes is accepted.
    return String(data: data, encoding: .utf8) != nil
  }

  public static func megabytes(_ bytes: Int) -> String {
    String(format: "%.1f", Double(bytes) / 1_048_576.0)
  }
}
