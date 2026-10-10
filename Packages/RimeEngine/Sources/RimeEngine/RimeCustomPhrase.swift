import Foundation

// MARK: - Phrases

/// One entry of Rime's `custom_phrase.txt`: the text a user wants, the code that produces it, and an
/// optional weight that decides where it ranks.
public struct RimeCustomPhrase: Sendable, Hashable, Codable {
  public var text: String
  public var code: String
  public var weight: Double?

  public init(text: String, code: String, weight: Double? = nil) {
    self.text = text
    self.code = code
    self.weight = weight
  }

  /// The tab-separated form Rime writes, without the weight when it is unset.
  public var line: String {
    if let weight {
      return text + "\t" + code + "\t" + Self.format(weight)
    }
    return text + "\t" + code
  }

  /// How a weight is written: an integer when it is one, so a file the user opens reads as they
  /// wrote it.
  public static func format(_ weight: Double) -> String {
    weight == weight.rounded() ? String(Int(weight)) : String(weight)
  }
}

// MARK: - The file

/// Rime's own `custom_phrase.txt`, read and written without a YAML parser.
///
/// The format is tab-separated and line-oriented — the same one the desktop writes — so this is a
/// reader and a writer rather than a config: nothing here goes through librime, and nothing is
/// reordered. A line the user wrote by hand that this type does not understand is reported, not
/// dropped, because the file belongs to them.
public enum RimeCustomPhraseFile {
  /// A line this reader could not understand. It keeps its 1-based number so the screen can point at
  /// it rather than silently losing an entry the user wrote.
  public struct RejectedLine: Sendable, Hashable {
    public let line: Int
    public let text: String

    public init(line: Int, text: String) {
      self.line = line
      self.text = text
    }
  }

  public struct ParseResult: Sendable, Hashable {
    public var phrases: [RimeCustomPhrase]
    public var rejected: [RejectedLine]

    public init(phrases: [RimeCustomPhrase], rejected: [RejectedLine] = []) {
      self.phrases = phrases
      self.rejected = rejected
    }
  }

  public static func parse(_ text: String) -> ParseResult {
    var phrases: [RimeCustomPhrase] = []
    var rejected: [RejectedLine] = []
    for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else {
        rejected.append(RejectedLine(line: index + 1, text: line))
        continue
      }
      let weight = fields.count >= 3 ? Double(fields[2].trimmingCharacters(in: .whitespaces)) : nil
      phrases.append(RimeCustomPhrase(text: fields[0], code: fields[1], weight: weight))
    }
    return ParseResult(phrases: phrases, rejected: rejected)
  }

  public static func serialize(_ phrases: [RimeCustomPhrase]) -> String {
    // A trailing newline, because every tool that reads this file expects one line per phrase.
    phrases.map(\.line).joined(separator: "\n") + (phrases.isEmpty ? "" : "\n")
  }

  public static func load(from url: URL) throws -> ParseResult {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return ParseResult(phrases: [])
    }
    return parse(try String(contentsOf: url, encoding: .utf8))
  }

  public static func save(_ phrases: [RimeCustomPhrase], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try serialize(phrases).write(to: url, atomically: true, encoding: .utf8)
  }

  /// Some schemas (including Rime Ice's double pinyin schemas) use a separate native
  /// phrase file. Add a second translator for the app's shared phrases, preserving that
  /// file and its existing translator. Only user patches are changed, never profile sources.
  static func connectToSchemas(in source: URL, workspace: RimeWorkspace, engine: RimeEngine) throws {
    let phrases = try load(from: workspace.userData.appendingPathComponent("custom_phrase.txt"))
    guard !phrases.phrases.isEmpty else { return }
    for schemaID in RimeTreeClassifier.classify(root: source).schemaIDs {
      let yaml = try String(contentsOf: source.appendingPathComponent(schemaID + ".schema.yaml"),
                            encoding: .utf8)
      let config = try engine.configFromYAML(yaml)
      defer { config.close() }
      let patch = RimePatch(engine: engine, configID: schemaID)
      let original = try patch.entries()
      var entries = original
      let translators = (entries["engine/translators"] ?? config.value("engine/translators"))?
        .listValue ?? []
      guard translators.contains(.string("table_translator@custom_phrase")) else { continue }
      let dictionary = (entries["custom_phrase/user_dict"] ?? config.value("custom_phrase/user_dict"))?
        .stringValue
      let database = (entries["custom_phrase/db_class"] ?? config.value("custom_phrase/db_class"))?
        .stringValue
      if dictionary == "custom_phrase", database == "stabledb" || database == "tabledb" { continue }

      let translator = RimeConfigValue.string("table_translator@arkey_custom_phrase")
      var appended = entries["engine/translators/+"]?.listValue ?? []
      if !translators.contains(translator), !appended.contains(translator) {
        appended.append(translator)
        entries["engine/translators/+"] = .list(appended)
      }
      entries["arkey_custom_phrase/dictionary"] = .string("")
      entries["arkey_custom_phrase/user_dict"] = .string("custom_phrase")
      entries["arkey_custom_phrase/db_class"] = .string("stabledb")
      entries["arkey_custom_phrase/enable_completion"] = .bool(false)
      entries["arkey_custom_phrase/enable_sentence"] = .bool(false)
      entries["arkey_custom_phrase/initial_quality"] = .int(99)
      guard entries != original else { continue }
      _ = try patch.snapshot(into: workspace.root.appendingPathComponent("backups"))
      try patch.write(entries)
    }
  }

  /// How an imported list meets the one that is already there (S2 §3: "an explicit merge, never a
  /// silent overwrite").
  public static func merge(_ incoming: [RimeCustomPhrase],
                           into existing: [RimeCustomPhrase],
                           strategy: RimeCustomPhraseMerge) -> [RimeCustomPhrase] {
    switch strategy {
    case .replaceAll:
      return incoming
    case .keepExisting:
      return existing
    case .appendNew:
      var seen = Set(existing.map { $0.text + "\u{1}" + $0.code })
      var result = existing
      for phrase in incoming where seen.insert(phrase.text + "\u{1}" + phrase.code).inserted {
        result.append(phrase)
      }
      return result
    }
  }
}

public enum RimeCustomPhraseMerge: String, Sendable, CaseIterable {
  /// The imported file wins, entirely.
  case replaceAll
  /// What is already there wins; the import is reported and not applied.
  case keepExisting
  /// Both survive: entries the file does not already have are added.
  case appendNew
}
