import Foundation

// MARK: - Translator kind

/// S2 §2's second rule: the UI is generated from what the schema actually declares, so it cannot
/// offer a knob that does nothing.
///
/// The distinction that matters is the translator in front of us. A pinyin schema uses a *script*
/// translator, which reads `enable_completion` and `enable_word_completion` and ignores
/// `enable_sentence` and `enable_encoder`; a table translator (wubi, cangjie, a 码表 schema) is the
/// other way round. Offering one generic switch list is how a settings screen ends up with toggles
/// that change nothing.
public enum RimeTranslatorKind: String, Sendable, Hashable {
  case script
  case table
  case other

  public static func classify(_ translatorNames: [String]) -> RimeTranslatorKind {
    if translatorNames.contains(where: { $0.hasPrefix("script_translator") || $0.hasPrefix("pinyin") }) {
      return .script
    }
    if translatorNames.contains(where: { $0.contains("table_translator") || $0.contains("reverse_lookup") }) {
      return .table
    }
    return .other
  }
}

// MARK: - Descriptors

public struct RimeSwitchDescriptor: Sendable, Hashable {
  public let name: String
  /// The words the schema gives the two states.
  public let states: [String]
  /// Which state a fresh session starts in, as the deployed configuration has it.
  public let reset: Int
  /// True when the user has a `switches` patch for this schema at all.
  ///
  /// It is a **list-level** flag, not a per-switch one: Rime replaces a list wholesale, so setting one
  /// switch's `reset` writes every switch (see `RimeSettingsModel.setSwitchReset`). A screen must
  /// therefore mark the switch section as modified rather than each row, or it would claim the user had
  /// chosen a value they never touched.
  /// The same words through `get_state_label`, which is where S2 wants them from. Empty when no
  /// session is open, because that call needs one.
  public let labels: [String]
  public let effective: Bool?
  public let isUserSet: Bool

  public var displayLabels: [String] {
    labels.isEmpty ? states : labels
  }
}

public struct RimeSettingDescriptor: Sendable, Hashable {
  public enum Value: Sendable, Hashable {
    case boolean(Bool)
    case integer(Int)
    case text(String)
    case list([String])

    public var displayText: String {
      switch self {
      case .boolean(let value): return value ? "开" : "关"
      case .integer(let value): return String(value)
      case .text(let value): return value
      case .list(let values): return values.joined(separator: ", ")
      }
    }
  }

  public enum Scope: Sendable, Hashable {
    /// Written to `default.custom.yaml`.
    case defaultConfig
    /// Written to `<schema>.custom.yaml`.
    case schema(String)
  }

  public let id: String
  public let title: String
  public let key: String
  public let scope: Scope
  public let effective: Value?
  /// Present only when the user has patched the key, which is what "reset to default" acts on.
  public let userValue: Value?
  public let note: String?

  public var isUserSet: Bool { userValue != nil }
}

public struct RimeSchemaDescriptor: Sendable {
  public let schemaID: String
  public let name: String
  public let translatorKind: RimeTranslatorKind
  public let translatorNames: [String]
  public let dictionary: String?
  public let hasUserDictionary: Bool
  public let switches: [RimeSwitchDescriptor]
  public let settings: [RimeSettingDescriptor]
  public let pageSize: Int
  public let hasPunctuator: Bool
  public let hasGrammar: Bool

  public func setting(_ id: String) -> RimeSettingDescriptor? {
    settings.first { $0.id == id }
  }
}

// MARK: - Model

/// S2 §3's table, generated per schema rather than hard-coded per screen.
public enum RimeSettingsModel {
  public static func describeSchema(_ schemaID: String, engine: RimeEngine) throws -> RimeSchemaDescriptor {
    let schemaPatch = RimePatch(engine: engine, configID: schemaID)
    var name = schemaID
    var translatorNames: [String] = []
    var dictionary: String?
    var hasUserDictionary = false
    var switches: [RimeSwitchDescriptor] = []
    var settings: [RimeSettingDescriptor] = []
    var pageSize = 5
    var hasPunctuator = false
    var hasGrammar = false

    try engine.withSchemaConfig(schemaID) { config in
      name = config.string("schema/name") ?? schemaID
      translatorNames = (config.value("engine/translators")?.listValue ?? []).compactMap(\.stringValue)
      dictionary = config.string("translator/dictionary")
      hasUserDictionary = config.bool("translator/enable_user_dict") ?? false
      hasPunctuator = config.value("punctuator") != nil
      hasGrammar = config.value("grammar") != nil

      switches = parseSwitches(config, engine: engine, patch: schemaPatch,
                               userPatchedSwitches: (try? schemaPatch.userValue("switches")) != nil)
    }

    let kind = RimeTranslatorKind.classify(translatorNames)
    // Page size is a default-config setting, not a schema one.
    pageSize = (try? engine.withConfig("default") { $0.int("menu/page_size") }) ?? 5

    if kind == .script {
      settings.append(boolean("completion", "逐码提示", "translator/enable_completion",
                              scope: .schema(schemaID), engine: engine, patch: schemaPatch,
                              note: "librime 默认为开；雾凇拼音的用户常把它关掉"))
      settings.append(boolean("wordCompletion", "词条提示", "translator/enable_word_completion",
                              scope: .schema(schemaID), engine: engine, patch: schemaPatch, note: nil))
      settings.append(integer("maxSentences", "最长整句词数", "translator/max_sentences",
                              scope: .schema(schemaID), engine: engine, patch: schemaPatch,
                              note: "脚本翻译器始终尝试整句；这是它的上界"))
      settings.append(integer("sentenceCutoff", "整句可信度阈值", "translator/sentence_cutoff_threshold",
                              scope: .schema(schemaID), engine: engine, patch: schemaPatch, note: nil))
    } else if kind == .table {
      settings.append(boolean("sentence", "整句输入", "translator/enable_sentence",
                              scope: .schema(schemaID), engine: engine, patch: schemaPatch,
                              note: "码表翻译器的开关；拼音方案不读它"))
      settings.append(boolean("encoder", "自动造词", "translator/enable_encoder",
                              scope: .schema(schemaID), engine: engine, patch: schemaPatch,
                              note: "码表翻译器的开关；拼音方案不读它"))
    }

    settings.append(boolean("userDictionary", "用户词典（学习）", "translator/enable_user_dict",
                            scope: .schema(schemaID), engine: engine, patch: schemaPatch,
                            note: "关闭后不会学习新词，已有词库保留（S5）"))
    settings.append(boolean("alwaysShowComments", "始终显示候选注释", "translator/always_show_comments",
                            scope: .schema(schemaID), engine: engine, patch: schemaPatch, note: nil))
    settings.append(integer("spellingHints", "逐键提示数", "translator/spelling_hints",
                            scope: .schema(schemaID), engine: engine, patch: schemaPatch, note: nil))
    settings.append(integer("pageSize", "每页候选数", "menu/page_size",
                            scope: .defaultConfig, engine: engine,
                            patch: RimePatch(engine: engine, configID: "default"),
                            note: "写入 default.custom.yaml"))

    return RimeSchemaDescriptor(schemaID: schemaID, name: name, translatorKind: kind,
                                translatorNames: translatorNames, dictionary: dictionary,
                                hasUserDictionary: hasUserDictionary, switches: switches,
                                settings: settings, pageSize: pageSize,
                                hasPunctuator: hasPunctuator, hasGrammar: hasGrammar)
  }

  /// Sets one switch's default state for a schema.
  ///
  /// Measured, and it is not the obvious implementation: writing `patch/switches/@0/reset`
  /// **replaces the whole** `switches` list, so the deployed schema ends up with a single nameless
  /// entry and every switch loses its states. Rime replaces a list wholesale, which is why this reads
  /// the effective list, changes one element's `reset`, and writes the list back — the same rule
  /// S2 §2.1 already applies to `schema_list`.
  @discardableResult
  public static func setSwitchReset(_ reset: Int, forSwitch name: String, schemaID: String,
                                    engine: RimeEngine) throws -> RimeConfigChange {
    let effective = try engine.withSchemaConfig(schemaID) { $0.value("switches") }?.listValue ?? []
    var found = false
    let updated: [RimeConfigValue] = effective.map { entry in
      guard var map = entry.mapValue, map["name"]?.stringValue == name else { return entry }
      found = true
      map["reset"] = .int(reset)
      return .map(map)
    }
    guard found else { throw RimePatchError.switchNotInSchema(name) }
    return try RimePatch(engine: engine, configID: schemaID).set(.list(updated), at: "switches")
  }

  /// The settings that belong to no single schema: what the 配置库 screen writes to
  /// `default.custom.yaml`.
  public static func globalSettings(engine: RimeEngine) throws -> [RimeSettingDescriptor] {
    let patch = RimePatch(engine: engine, configID: "default")
    let merged = try engine.withConfig("default") { config -> [RimeSettingDescriptor] in
      let pageSize = config.int("menu/page_size")
      let page = RimeSettingDescriptor(id: "pageSize", title: "每页候选数", key: "menu/page_size",
                                       scope: .defaultConfig,
                                       effective: pageSize.map { .integer($0) },
                                       userValue: nil, note: nil)
      return [page]
    }
    // The user's own value is read from the patch file, which is what "reset" acts on.
    return try merged.map { descriptor in
      RimeSettingDescriptor(id: descriptor.id, title: descriptor.title, key: descriptor.key,
                            scope: descriptor.scope, effective: descriptor.effective,
                            userValue: try patch.userValue(descriptor.key).flatMap(Self.value(from:)),
                            note: descriptor.note)
    }
  }

  // MARK: Helpers

  private static func parseSwitches(_ config: RimeConfigRef, engine: RimeEngine,
                                    patch: RimePatch,
                                    userPatchedSwitches: Bool) -> [RimeSwitchDescriptor] {
    guard let entries = config.value("switches")?.listValue else { return [] }
    var descriptors: [RimeSwitchDescriptor] = []
    for (index, entry) in entries.enumerated() {
      guard let map = entry.mapValue, let name = map["name"]?.stringValue else { continue }
      let states = (map["states"]?.listValue ?? []).compactMap(\.stringValue)
      let reset = map["reset"]?.intValue ?? 0
      var labels: [String] = []
      if let first = try? engine.stateLabel(option: name, state: false) {
        labels.append(first)
      }
      if states.count > 1, let second = try? engine.stateLabel(option: name, state: true) {
        labels.append(second)
      }
      let effective = (try? engine.getOption(name))
      descriptors.append(RimeSwitchDescriptor(name: name, states: states, reset: reset,
                                              labels: labels.count == states.count ? labels : [],
                                              effective: effective,
                                              isUserSet: userPatchedSwitches))
    }
    return descriptors
  }

  private static func boolean(_ id: String, _ title: String, _ key: String,
                              scope: RimeSettingDescriptor.Scope, engine: RimeEngine,
                              patch: RimePatch, note: String?) -> RimeSettingDescriptor {
    let effective = effective(key, scope: scope, engine: engine, patch: patch)?.boolValue
    let user = (try? patch.userValue(key)).flatMap(Self.value(from:))
    return RimeSettingDescriptor(id: id, title: title, key: key, scope: scope,
                                 effective: effective.map { .boolean($0) },
                                 userValue: user, note: note)
  }

  private static func integer(_ id: String, _ title: String, _ key: String,
                              scope: RimeSettingDescriptor.Scope, engine: RimeEngine,
                              patch: RimePatch, note: String?) -> RimeSettingDescriptor {
    let effective = effective(key, scope: scope, engine: engine, patch: patch)?.intValue
    let user = (try? patch.userValue(key)).flatMap(Self.value(from:))
    return RimeSettingDescriptor(id: id, title: title, key: key, scope: scope,
                                 effective: effective.map { .integer($0) },
                                 userValue: user, note: note)
  }

  /// The value in force, asked the one way. The scope decides which config answers, and for a schema that is
  /// the same question `RimePatch.effectiveValue` answers — which is why this delegates there. The default
  /// config has no schema behind it, and the two helpers used to disagree about that: `integer` read it
  /// through `withConfig`, `boolean` through `withSchemaConfig("default")`, which is not a schema at all. No
  /// boolean descriptor uses that scope today; removing the trap is the point.
  private static func effective(_ key: String, scope: RimeSettingDescriptor.Scope,
                                engine: RimeEngine, patch: RimePatch) -> RimeConfigValue? {
    if case .defaultConfig = scope {
      return try? engine.withConfig(patch.configID) { $0.value(key) }
    }
    return try? patch.effectiveValue(key, schemaID: schemaID(of: scope))
  }

  private static func schemaID(of scope: RimeSettingDescriptor.Scope) -> String {
    if case .schema(let id) = scope { return id }
    return "default"
  }

  static func value(from value: RimeConfigValue) -> RimeSettingDescriptor.Value {
    switch value {
    case .bool(let raw): return .boolean(raw)
    case .int(let raw): return .integer(raw)
    case .double(let raw): return .text(String(raw))
    case .string(let raw): return .text(raw)
    case .list(let items): return .list(items.compactMap(\.stringValue))
    case .map: return .text(value.compactDescription)
    }
  }
}
