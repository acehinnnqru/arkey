import Foundation

// MARK: - Punctuation

/// S2 §3's punctuation row: "the app exposes the choice, not the tables".
///
/// A Rime schema punctuates by importing a symbols table — rime-ice ships `symbols_v.yaml`, the
/// shipped default is `symbols.yaml` — so the choice here is which table to import, written as one
/// patch key. 全角/半角 and 中英标点 are *switch* states, not tables, and live in the switch section.
public struct RimePunctuationPreset: Sendable, Hashable, Identifiable {
  public let id: String
  public let displayName: String
  /// The value written to `punctuator/import_preset`.
  public let importPreset: String
  public let note: String
  /// True when the schema actually ships the file this preset names. A preset whose table is not in
  /// the profile is offered only as a warning, because importing a preset that is not there leaves the
  /// schema with no punctuation at all.
  public let requiresFile: String?

  public init(id: String, displayName: String, importPreset: String, note: String,
              requiresFile: String? = nil) {
    self.id = id
    self.displayName = displayName
    self.importPreset = importPreset
    self.note = note
    self.requiresFile = requiresFile
  }
}

public enum RimePunctuation {
  public static let presets: [RimePunctuationPreset] = [
    .init(id: "default", displayName: "Rime 内置", importPreset: "default",
          note: "不导入任何随包表，使用 librime 自带的标点映射。"),
    .init(id: "symbols", displayName: "默认符号表", importPreset: "symbols",
          note: "配置自带的 symbols.yaml。", requiresFile: "symbols.yaml"),
    .init(id: "symbols_v", displayName: "增强符号表", importPreset: "symbols_v",
          note: "雾凇拼音的 symbols_v.yaml：标点更全，且带竖排符号。",
          requiresFile: "symbols_v.yaml"),
  ]

  public static func preset(id: String) -> RimePunctuationPreset? {
    presets.first { $0.id == id }
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
  public static let options: [RimeKeyBindingOption] = [
    .init(id: "page_minus_equal", displayName: "翻页：- 和 =",
          note: "常见的 Rime 习惯：减号上一页，等号下一页。",
          bindings: [
            RimeKeyBindingOption.binding("paging", "-", "Page_Up"),
            RimeKeyBindingOption.binding("has_menu", "=", "Page_Down"),
          ]),
    .init(id: "page_bracket", displayName: "翻页：[ 和 ]",
          note: "把翻页交给方括号，减号与等号留给别处。",
          bindings: [
            RimeKeyBindingOption.binding("paging", "bracketleft", "Page_Up"),
            RimeKeyBindingOption.binding("has_menu", "bracketright", "Page_Down"),
          ]),
    .init(id: "select_semicolon_quote", displayName: "选词：; 和 '",
          note: "分号选第二候选，引号选第三候选。",
          bindings: [
            RimeKeyBindingOption.binding("has_menu", "semicolon", "2"),
            RimeKeyBindingOption.binding("has_menu", "apostrophe", "3"),
          ]),
    .init(id: "word_selection", displayName: "以词定字：[ 和 ]",
          note: "在没有翻页冲突的方案里，方括号取词的首字与末字。",
          bindings: [
            RimeKeyBindingOption.binding("has_menu", "bracketleft", "commit_comment"),
            RimeKeyBindingOption.binding("has_menu", "bracketright", "commit_raw_input"),
          ]),
  ]

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
