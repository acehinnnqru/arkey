import Foundation
import XCTest
@testable import RimeEngine

final class LocalizationTests: XCTestCase {
  func testMissingAndUnsupportedPreferencesDefaultToChinese() {
    for value in [nil, "", "fr", "zh", "invalid"] as [String?] {
      XCTAssertEqual(RimeAppLanguage.resolve(value), .chinese)
    }
    XCTAssertEqual(RimeAppLanguage.resolve("en"), .english)
    XCTAssertEqual(RimeAppLanguage.resolve("zh-Hans"), .chinese)
  }

  func testSharedResourcesResolveBothLanguagesExplicitly() {
    XCTAssertEqual(RimeLocalization.text("Settings", language: .chinese), "设置")
    XCTAssertEqual(RimeLocalization.text("Settings", language: .english), "Settings")
    XCTAssertEqual(RimeLocalization.text("Next keyboard", language: .chinese), "下一个键盘")
    XCTAssertEqual(RimeLocalization.text("Next keyboard", language: .english), "Next keyboard")
    XCTAssertEqual(RimeLocalization.text("", language: .chinese), "")
    XCTAssertEqual(RimeLocalization.key("Unknown source key", language: .english), "Unknown source key")
  }

  func testSystemPreferenceMatchesSupportedLanguagesInOrder() {
    XCTAssertEqual(RimeAppLanguage.resolve("system"), .system)
    XCTAssertEqual(RimeAppLanguage.system.resolved(preferredLanguages: ["en-US", "zh-Hans"]), .english)
    XCTAssertEqual(RimeAppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en"]), .chinese)
    XCTAssertEqual(RimeAppLanguage.system.resolved(preferredLanguages: ["fr-FR", "en-GB"]), .english)
    XCTAssertEqual(RimeAppLanguage.system.resolved(preferredLanguages: ["fr-FR"]), .chinese)
    XCTAssertEqual(RimeAppLanguage.system.resolved(preferredLanguages: []), .chinese)
    XCTAssertEqual(RimeAppLanguage.chinese.resolved(preferredLanguages: ["en"]), .chinese)
    XCTAssertEqual(RimeAppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]), .english)
    XCTAssertEqual(RimeLocalization.text("Follow System", language: .chinese), "跟随系统")
    XCTAssertEqual(RimeLocalization.text("Follow System", language: .english), "Follow System")
  }

  func testInterpolatedValuesAreLiteralAndCanBeReordered() {
    let source = "backup-{1}-%@.txt"
    let dictionary = "你好-{0}"
    let message = RimeLocalization.message("Restored from \(source) dictionary \(dictionary)")
    XCTAssertEqual(message.render(language: .chinese), "已从 " + source + " 恢复 " + dictionary)
    XCTAssertEqual(message.render(language: .english), "Restored " + dictionary + " from " + source)
  }

  func testRetainedAndNestedMessagesRenderInTheNewLanguage() {
    let detail = RimeLocalization.message("Profile changed")
    let message = RimeLocalization.message("Applied: \(detail)")
    XCTAssertEqual(message.render(language: .chinese), "已生效：已切换")
    XCTAssertEqual(message.render(language: .english), "Applied: Profile changed")
    let external = RimeLocalizedMessage(verbatim: "用户方案 / schema_list/0 / 100%")
    XCTAssertEqual(external.render(language: .english), "用户方案 / schema_list/0 / 100%")
  }

  func testLanguagePersistsSeparatelyFromKeyboardPreferenceReset() throws {
    let suite = "arkey.localization.tests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = RimeAppLanguageStore(defaults: defaults)
    XCTAssertEqual(store.value, .chinese)
    store.value = .english
    XCTAssertEqual(RimeAppLanguageStore(defaults: defaults).value, .english)
    RimeKeyboardPreferencesStore(defaults: defaults).reset()
    XCTAssertEqual(store.value, .english)
    store.value = .system
    XCTAssertEqual(RimeAppLanguageStore(defaults: defaults).value, .system)
    RimeKeyboardPreferencesStore(defaults: defaults).reset()
    XCTAssertEqual(store.value, .system)
    defaults.set("unsupported", forKey: RimeLocalization.storageKey)
    XCTAssertEqual(store.value, .chinese)
  }
}
