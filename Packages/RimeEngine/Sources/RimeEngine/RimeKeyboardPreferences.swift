import Foundation

/// The radical_pinyin schema compiles one spelling algebra at a time. Its bundled
/// alternatives cover full pinyin and the double-pinyin schemas shipped by Rime Ice.
public enum RimeAuxiliarySpelling: String, Sendable, Hashable, CaseIterable {
  case fullPinyin
  case doublePinyin
  case flypy
  case mspy
  case sogou
  case abc
  case ziguang
  case jiajia

  public var algebraKey: String {
    switch self {
    case .fullPinyin: return "algebra_rime_ice"
    case .doublePinyin: return "algebra_double_pinyin"
    case .flypy: return "algebra_double_pinyin_flypy"
    case .mspy: return "algebra_double_pinyin_mspy"
    case .sogou: return "algebra_double_pinyin_sogou"
    case .abc: return "algebra_double_pinyin_abc"
    case .ziguang: return "algebra_double_pinyin_ziguang"
    case .jiajia: return "algebra_double_pinyin_jiajia"
    }
  }

  public var label: String {
    switch self {
    case .fullPinyin: return RimeLocalization.text("Full pinyin")
    case .doublePinyin: return RimeLocalization.text("Natural Code double pinyin")
    case .flypy: return RimeLocalization.text("Flypy double pinyin")
    case .mspy: return RimeLocalization.text("Microsoft double pinyin")
    case .sogou: return RimeLocalization.text("Sogou double pinyin")
    case .abc: return RimeLocalization.text("Intelligent ABC double pinyin")
    case .ziguang: return RimeLocalization.text("Ziguang double pinyin")
    case .jiajia: return RimeLocalization.text("Pinyin Jiajia double pinyin")
    }
  }

  public var includePath: String {
    "radical_pinyin.schema.yaml:/" + algebraKey
  }
}

/// An optional key immediately beside Space. Character keys use the normal Rime input path.
public struct RimeSpaceSideKey: Codable, Sendable, Equatable {
  public enum Mode: String, Codable, Sendable, CaseIterable {
    case disabled, auxiliary, character
  }

  public var mode: Mode
  public var character: String

  public init(mode: Mode = .disabled, character: String = ",") {
    self.mode = mode
    self.character = character
  }

  /// Accept one printable ASCII key, including fullwidth equivalents.
  public static func normalizedCharacter(_ value: String) -> String? {
    guard value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else { return nil }
    let code = scalar.value
    let ascii = (0xFF01...0xFF5E).contains(code) ? code - 0xFEE0 : code
    guard (33...126).contains(ascii), let normalized = UnicodeScalar(ascii) else { return nil }
    return String(normalized)
  }

  public func input(auxiliaryPrefix: String?) -> String? {
    switch mode {
    case .disabled: return nil
    case .auxiliary: return auxiliaryPrefix.flatMap(RimeKeyboardPreferences.normalizedAuxiliaryPrefix)
    case .character: return Self.normalizedCharacter(character)
    }
  }
}

// MARK: - Preferences

/// The settings that are ours rather than Rime's (S2 §3's last row, S3 §4/§5's decisions).
///
/// They live in the app group's `UserDefaults` so the keyboard and the app agree without a deploy: the
/// keyboard cannot run a deploy, and a preference that needs one to take effect is a preference the
/// keyboard can never see.
public struct RimeKeyboardPreferences: Codable, Sendable, Equatable {
  /// S3 §4's open decision, as a value: let the system supply the backing material, or use the
  /// measured palette everywhere.
  public enum PaletteMode: String, Codable, Sendable, CaseIterable {
    case followHost
    case fixed
  }

  public enum CompositionDisplay: String, Codable, Sendable, CaseIterable {
    case rawInput
    case preedit
  }

  public enum AuxiliaryKeySide: String, Codable, Sendable, CaseIterable {
    case left, right
  }

  /// Rime keysyms use ASCII punctuation. Normalize the corresponding fullwidth key cap
  /// before storing it, so a Chinese keyboard's `；` configures the same `;` key.
  public static func normalizedAuxiliaryPrefix(_ value: String) -> String? {
    guard value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else { return nil }
    let code = scalar.value
    let ascii = (0xFF01...0xFF5E).contains(code) ? code - 0xFEE0 : code
    guard (33...126).contains(ascii),
          let normalized = UnicodeScalar(ascii),
          CharacterSet.punctuationCharacters.contains(normalized) || CharacterSet.symbols.contains(normalized)
    else { return nil }
    return String(normalized)
  }

  public static func isValidAuxiliaryPrefix(_ value: String) -> Bool {
    normalizedAuxiliaryPrefix(value) != nil
  }

  public var leftSpaceKey: RimeSpaceSideKey
  public var rightSpaceKey: RimeSpaceSideKey
  public var auxiliaryPrefix: String
  /// Retained for decoding older exports; side-key visibility is configured independently.
  public var auxiliaryKeySide: AuxiliaryKeySide
  public var compositionDisplay: CompositionDisplay
  public var paletteMode: PaletteMode
  /// S3 §5: the click sound and the haptic fire only when the user enabled them.
  public var keyClickEnabled: Bool
  public var hapticsEnabled: Bool
  public var calloutEnabled: Bool
  public var chineseInputOnly: Bool
  public var capsLockEnabled: Bool
  /// The calibrated repeat timing, so a device pass changes one stored value rather than a constant.
  public var deleteRepeatDelay: TimeInterval
  public var deleteRepeatInterval: TimeInterval

  public init(auxiliaryPrefix: String = ",",
              auxiliaryKeySide: AuxiliaryKeySide = .right,
              leftSpaceKey: RimeSpaceSideKey = RimeSpaceSideKey(),
              rightSpaceKey: RimeSpaceSideKey = RimeSpaceSideKey(),
              paletteMode: PaletteMode = .followHost,
              compositionDisplay: CompositionDisplay = .rawInput,
              keyClickEnabled: Bool = true,
              hapticsEnabled: Bool = true,
              calloutEnabled: Bool = true,
              capsLockEnabled: Bool = true,
              chineseInputOnly: Bool = false,
              deleteRepeatDelay: TimeInterval = RimeKeyFeedback.standard.deleteRepeatDelay,
              deleteRepeatInterval: TimeInterval = RimeKeyFeedback.standard.deleteRepeatInterval) {
    self.auxiliaryPrefix = Self.normalizedAuxiliaryPrefix(auxiliaryPrefix) ?? ","
    self.auxiliaryKeySide = auxiliaryKeySide
    self.leftSpaceKey = leftSpaceKey
    self.rightSpaceKey = rightSpaceKey
    self.compositionDisplay = compositionDisplay
    self.paletteMode = paletteMode
    self.keyClickEnabled = keyClickEnabled
    self.hapticsEnabled = hapticsEnabled
    self.calloutEnabled = calloutEnabled
    self.capsLockEnabled = capsLockEnabled
    self.chineseInputOnly = chineseInputOnly
    self.deleteRepeatDelay = deleteRepeatDelay
    self.deleteRepeatInterval = deleteRepeatInterval
  }

  public static let standard = RimeKeyboardPreferences()

  // Decoded field by field so that a blob written by an older or newer build keeps every value it
  // does have and defaults the rest. Synthesized Codable would reject the whole blob over one missing
  // key, which turns a future field into a silent reset of the user's settings.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let standard = RimeKeyboardPreferences()
    leftSpaceKey = (try? container.decode(RimeSpaceSideKey.self, forKey: .leftSpaceKey)) ?? standard.leftSpaceKey
    rightSpaceKey = (try? container.decode(RimeSpaceSideKey.self, forKey: .rightSpaceKey)) ?? standard.rightSpaceKey
    let prefix = try container.decodeIfPresent(String.self, forKey: .auxiliaryPrefix) ?? standard.auxiliaryPrefix
    auxiliaryPrefix = Self.normalizedAuxiliaryPrefix(prefix) ?? standard.auxiliaryPrefix
    auxiliaryKeySide = try container.decodeIfPresent(AuxiliaryKeySide.self, forKey: .auxiliaryKeySide)
      ?? standard.auxiliaryKeySide
    compositionDisplay = try container.decodeIfPresent(CompositionDisplay.self, forKey: .compositionDisplay)
      ?? standard.compositionDisplay
    paletteMode = try container.decodeIfPresent(PaletteMode.self, forKey: .paletteMode)
      ?? standard.paletteMode
    keyClickEnabled = try container.decodeIfPresent(Bool.self, forKey: .keyClickEnabled)
      ?? standard.keyClickEnabled
    hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled)
      ?? standard.hapticsEnabled
    calloutEnabled = try container.decodeIfPresent(Bool.self, forKey: .calloutEnabled)
      ?? standard.calloutEnabled
    chineseInputOnly = try container.decodeIfPresent(Bool.self, forKey: .chineseInputOnly)
      ?? standard.chineseInputOnly
    capsLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .capsLockEnabled)
      ?? standard.capsLockEnabled
    deleteRepeatDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .deleteRepeatDelay)
      ?? standard.deleteRepeatDelay
    deleteRepeatInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .deleteRepeatInterval)
      ?? standard.deleteRepeatInterval
  }

  /// Only changes the client's temporary marked text; candidates and commits remain engine-owned.
  public func markedText(for output: RimeOutput) -> String? {
    switch compositionDisplay {
    case .rawInput: return output.segmentedInput
    case .preedit: return output.preedit
    }
  }

  /// The feedback policy these preferences describe, so the view never keeps a second copy of the
  /// timing constants.
  public var feedback: RimeKeyFeedback {
    var feedback = RimeKeyFeedback.standard
    feedback.deleteRepeatDelay = deleteRepeatDelay
    feedback.deleteRepeatInterval = deleteRepeatInterval
    return feedback
  }

  /// Whether a callout may be raised at all, given this preference and the device class.
  public func allowsCallout(isPhoneClass: Bool) -> Bool {
    guard calloutEnabled else { return false }
    return RimeKeyFeedback.standard.calloutOnPhoneClassOnly ? isPhoneClass : true
  }
}

// MARK: - Store

/// The app group's `UserDefaults`, with the preferences as one JSON blob under one key.
///
/// One key rather than a key per field: the encoding carries its own defaults, so a field added later
/// is a missing key that decodes to its default rather than a crash or a silent zero.
///
/// This is the app's only use of `UserDefaults`, and it is why the privacy manifest declares
/// `NSPrivacyAccessedAPICategoryUserDefaults` with reason `1C8F.1` (the app group). If this type ever
/// stops using it, the manifest and its test have to change together.
public final class RimeKeyboardPreferencesStore: @unchecked Sendable {
  public static let appGroupID = "group.com.acehinnnqru.arkey"
  public static let storageKey = "arkey.keyboard.preferences"

  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults, key: String = RimeKeyboardPreferencesStore.storageKey) {
    self.defaults = defaults
    self.key = key
  }

  /// The shared store, or nil when the app group does not resolve — in which case the keyboard runs
  /// on the standard preferences and says so in diagnostics rather than guessing.
  public static func appGroup(databaseID: String = RimeKeyboardPreferencesStore.appGroupID)
    -> RimeKeyboardPreferencesStore? {
    guard let defaults = UserDefaults(suiteName: databaseID) else { return nil }
    return RimeKeyboardPreferencesStore(defaults: defaults)
  }

  public var value: RimeKeyboardPreferences {
    get {
      guard let data = defaults.data(forKey: key) else { return .standard }
      return (try? RimeJSON.decode(RimeKeyboardPreferences.self, from: data)) ?? .standard
    }
    set {
      guard let data = try? RimeJSON.encode(newValue, pretty: false) else { return }
      defaults.set(data, forKey: key)
    }
  }

  /// Back to the shipped defaults, which is what a "恢复默认" button means.
  public func reset() {
    defaults.removeObject(forKey: key)
  }
}
