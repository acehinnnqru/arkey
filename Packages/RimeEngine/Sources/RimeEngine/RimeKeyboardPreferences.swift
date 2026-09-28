import Foundation

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

  public var paletteMode: PaletteMode
  /// S3 §5: the click sound and the haptic fire only when the user enabled them.
  public var keyClickEnabled: Bool
  public var hapticsEnabled: Bool
  public var calloutEnabled: Bool
  public var capsLockEnabled: Bool
  /// The calibrated repeat timing, so a device pass changes one stored value rather than a constant.
  public var deleteRepeatDelay: TimeInterval
  public var deleteRepeatInterval: TimeInterval

  public init(paletteMode: PaletteMode = .followHost,
              keyClickEnabled: Bool = true,
              hapticsEnabled: Bool = true,
              calloutEnabled: Bool = true,
              capsLockEnabled: Bool = true,
              deleteRepeatDelay: TimeInterval = RimeKeyFeedback.standard.deleteRepeatDelay,
              deleteRepeatInterval: TimeInterval = RimeKeyFeedback.standard.deleteRepeatInterval) {
    self.paletteMode = paletteMode
    self.keyClickEnabled = keyClickEnabled
    self.hapticsEnabled = hapticsEnabled
    self.calloutEnabled = calloutEnabled
    self.capsLockEnabled = capsLockEnabled
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
    paletteMode = try container.decodeIfPresent(PaletteMode.self, forKey: .paletteMode)
      ?? standard.paletteMode
    keyClickEnabled = try container.decodeIfPresent(Bool.self, forKey: .keyClickEnabled)
      ?? standard.keyClickEnabled
    hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled)
      ?? standard.hapticsEnabled
    calloutEnabled = try container.decodeIfPresent(Bool.self, forKey: .calloutEnabled)
      ?? standard.calloutEnabled
    capsLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .capsLockEnabled)
      ?? standard.capsLockEnabled
    deleteRepeatDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .deleteRepeatDelay)
      ?? standard.deleteRepeatDelay
    deleteRepeatInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .deleteRepeatInterval)
      ?? standard.deleteRepeatInterval
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
