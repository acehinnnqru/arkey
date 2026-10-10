import Foundation

/// Interface language is independent of the schema's Chinese/ASCII input mode.
public enum RimeAppLanguage: String, CaseIterable, Sendable {
  case chinese = "zh-Hans"
  case english = "en"

  public var nativeName: String { self == .chinese ? "简体中文" : "English" }
  public var locale: Locale { Locale(identifier: rawValue) }

  public static func resolve(_ value: String?) -> Self {
    value.flatMap(Self.init(rawValue:)) ?? .chinese
  }
}

public final class RimeAppLanguageStore: @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults) { self.defaults = defaults }

  public var value: RimeAppLanguage {
    get { RimeAppLanguage.resolve(defaults.string(forKey: RimeLocalization.storageKey)) }
    set { defaults.set(newValue.rawValue, forKey: RimeLocalization.storageKey) }
  }
}

/// Uses the same app group as keyboard preferences. Resetting keyboard preferences does not reset language.
public enum RimeLocalization {
  public static let storageKey = "arkey.interface.language"
  private static let preferenceStore = UserDefaults(suiteName: RimeKeyboardPreferencesStore.appGroupID)
    .map(RimeAppLanguageStore.init(defaults:))
  private static let chineseBundle = localizedBundle(.chinese)
  private static let englishBundle = localizedBundle(.english)

  public static var language: RimeAppLanguage {
    get { preferenceStore?.value ?? .chinese }
    set { preferenceStore?.value = newValue }
  }

  public static func text(_ message: RimeLocalizedMessage, language: RimeAppLanguage? = nil) -> String {
    message.render(language: language ?? self.language)
  }

  public static func message(_ message: RimeLocalizedMessage) -> RimeLocalizedMessage { message }

  /// Dynamic keys are reserved for descriptors owned by Arkey, never imported names or candidate text.
  public static func key(_ key: String, language: RimeAppLanguage? = nil) -> String {
    let selected = language ?? self.language
    let bundle = selected == .chinese ? chineseBundle : englishBundle
    let fallback = chineseBundle.localizedString(forKey: key, value: key, table: nil)
    return bundle.localizedString(forKey: key, value: fallback, table: nil)
  }

  private static func localizedBundle(_ language: RimeAppLanguage) -> Bundle {
    guard let path = Bundle.module.path(forResource: language.rawValue.lowercased(), ofType: "lproj"),
          let bundle = Bundle(path: path) else { return Bundle.module }
    return bundle
  }
}

/// Retains keys and arguments until presentation, so already published messages change language too.
/// Indexed substitutions let translators reorder arguments. Values are never interpreted as format strings.
public struct RimeLocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation,
  CustomStringConvertible, Sendable, Hashable {
  private let key: String
  private let arguments: [RimeLocalizedMessage]
  private let isVerbatim: Bool

  public init(stringLiteral value: String) {
    key = value
    arguments = []
    isVerbatim = false
  }

  public init(verbatim value: String) {
    key = value
    arguments = []
    isVerbatim = true
  }

  public init(stringInterpolation: StringInterpolation) {
    key = stringInterpolation.key
    arguments = stringInterpolation.arguments
    isVerbatim = false
  }

  public var text: String { render(language: RimeLocalization.language) }
  public var description: String { text }
  public var isEmpty: Bool { key.isEmpty }
  public func contains(_ value: String) -> Bool { text.contains(value) }
  public func hasPrefix(_ value: String) -> Bool { text.hasPrefix(value) }

  public static func + (lhs: Self, rhs: String) -> Self { "\(lhs)\(rhs)" }
  public static func + (lhs: Self, rhs: Self) -> Self { "\(lhs)\(rhs)" }
  public static func + (lhs: String, rhs: Self) -> String { lhs + rhs.text }

  func render(language: RimeAppLanguage) -> String {
    if isVerbatim || key.isEmpty { return key }
    let template = RimeLocalization.key(key, language: language)
    // Scan the template once. Replacing tokens repeatedly would corrupt values containing another token.
    var result = ""
    var index = template.startIndex
    while index < template.endIndex {
      if template[index] == "{", let end = template[index...].firstIndex(of: "}"),
         let argument = Int(template[template.index(after: index)..<end]),
         arguments.indices.contains(argument) {
        result += arguments[argument].render(language: language)
        index = template.index(after: end)
      } else {
        result.append(template[index])
        index = template.index(after: index)
      }
    }
    return result
  }

  public struct StringInterpolation: StringInterpolationProtocol {
    fileprivate var key = ""
    fileprivate var arguments: [RimeLocalizedMessage] = []

    public init(literalCapacity: Int, interpolationCount: Int) {
      key.reserveCapacity(literalCapacity)
      arguments.reserveCapacity(interpolationCount)
    }

    public mutating func appendLiteral(_ literal: String) { key += literal }
    public mutating func appendInterpolation<T>(_ value: T) {
      key += "{\(arguments.count)}"
      arguments.append(RimeLocalizedMessage(verbatim: String(describing: value)))
    }
    public mutating func appendInterpolation(_ value: RimeLocalizedMessage) {
      key += "{\(arguments.count)}"
      arguments.append(value)
    }
  }
}

public extension Array where Element == RimeLocalizedMessage {
  func joined(separator: String) -> String { map(\.text).joined(separator: separator) }
}
