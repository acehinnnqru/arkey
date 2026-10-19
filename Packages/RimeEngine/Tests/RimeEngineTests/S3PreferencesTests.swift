import XCTest
@testable import RimeEngine

/// S3 §3's last row and §5's switches: the settings that are ours rather than Rime's, stored where the
/// keyboard and the app can both read them without a deploy.
final class S3PreferencesTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!
  private var store: RimeKeyboardPreferencesStore!

  override func setUpWithError() throws {
    suite = "arkey.tests." + UUID().uuidString
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    store = RimeKeyboardPreferencesStore(defaults: defaults)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suite)
  }

  func testLegacySideKeysRemainChineseAndEnglishDefaultsOff() throws {
    let data = Data(#"{"leftSpaceKey":{"mode":"character","character":";"},"rightSpaceKey":{"mode":"auxiliary","character":","},"hapticsEnabled":false}"#.utf8)
    let preferences = try RimeJSON.decode(RimeKeyboardPreferences.self, from: data)
    XCTAssertEqual(preferences.spaceSideKeys(isASCII: false).left.input(auxiliaryPrefix: ","), ";")
    XCTAssertEqual(preferences.spaceSideKeys(isASCII: false).right.mode, .auxiliary)
    XCTAssertEqual(preferences.spaceSideKeys(isASCII: true).left.mode, .disabled)
    XCTAssertEqual(preferences.spaceSideKeys(isASCII: true).right.mode, .disabled)
    XCTAssertFalse(preferences.hapticsEnabled)
  }

  func testDebugModeDefaultsOffForExistingSettingsAndPersistsIndependently() throws {
    XCTAssertFalse(store.value.debugModeEnabled)
    defaults.set(Data(#"{"hapticsEnabled":false,"chineseInputOnly":true}"#.utf8),
                 forKey: RimeKeyboardPreferencesStore.storageKey)
    XCTAssertFalse(store.value.debugModeEnabled)
    var preferences = store.value
    preferences.debugModeEnabled = true
    store.value = preferences
    XCTAssertTrue(store.value.debugModeEnabled)
    XCTAssertFalse(store.value.hapticsEnabled)
    XCTAssertTrue(store.value.chineseInputOnly)
    preferences.debugModeEnabled = false
    store.value = preferences
    XCTAssertFalse(store.value.debugModeEnabled)
    XCTAssertTrue(store.value.chineseInputOnly)
  }

  func testEnglishSideKeysPersistIndependentlyAndReset() throws {
    var preferences = RimeKeyboardPreferences(leftSpaceKey: .init(mode: .auxiliary))
    preferences.englishLeftSpaceKey = .init(mode: .character, character: ",")
    preferences.englishRightSpaceKey = .init(mode: .character, character: ".")
    store.value = preferences
    XCTAssertEqual(store.value, preferences)
    let imported = try RimeJSON.decode(RimeKeyboardPreferences.self, from: RimeJSON.encode(preferences))
    XCTAssertEqual(imported, preferences)
    XCTAssertEqual(imported.spaceSideKeys(isASCII: false).left.mode, .auxiliary)
    XCTAssertEqual(imported.spaceSideKeys(isASCII: false).right.mode, .disabled)
    XCTAssertEqual(imported.spaceSideKeys(isASCII: true).left.character, ",")
    XCTAssertEqual(imported.spaceSideKeys(isASCII: true).right.character, ".")
    store.reset()
    XCTAssertEqual(store.value.englishLeftSpaceKey.mode, .disabled)
    XCTAssertEqual(store.value.englishRightSpaceKey.mode, .disabled)
  }

  func testEnglishAuxiliarySettingsAreIgnoredWithoutLosingChineseSettings() throws {
    let data = Data(#"{"rightSpaceKey":{"mode":"auxiliary","character":","},"englishLeftSpaceKey":{"mode":"auxiliary","character":";"}}"#.utf8)
    var preferences = try RimeJSON.decode(RimeKeyboardPreferences.self, from: data)
    XCTAssertEqual(preferences.englishLeftSpaceKey.mode, .disabled)
    preferences.englishRightSpaceKey = .init(mode: .auxiliary)
    XCTAssertEqual(preferences.spaceSideKeys(isASCII: true).right.mode, .disabled)
    XCTAssertEqual(preferences.spaceSideKeys(isASCII: false).right.mode, .auxiliary)
  }

  func testChineseInputOnlyDefaultsOffAndPersistsWithoutResettingOtherSettings() throws {
    XCTAssertFalse(store.value.chineseInputOnly)
    defaults.set(Data(#"{"hapticsEnabled":false}"#.utf8),
                 forKey: RimeKeyboardPreferencesStore.storageKey)
    XCTAssertFalse(store.value.chineseInputOnly)
    var preferences = store.value
    preferences.chineseInputOnly = true
    store.value = preferences
    XCTAssertTrue(store.value.chineseInputOnly)
    XCTAssertFalse(store.value.hapticsEnabled)
    store.reset()
    XCTAssertFalse(store.value.chineseInputOnly)
  }

  func testAFreshStoreHandsBackTheShippedDefaults() {
    XCTAssertEqual(store.value, .standard)
    XCTAssertEqual(store.value.paletteMode, .followHost, "the material path is the recommendation")
    XCTAssertTrue(store.value.keyClickEnabled)
    XCTAssertTrue(store.value.calloutEnabled)
    XCTAssertEqual(store.value.deleteRepeatDelay, 0.5)
    XCTAssertEqual(store.value.deleteRepeatInterval, 0.1)
  }

  func testRetiredExperimentSettingDoesNotResetExistingPreferences() throws {
    for enabled in [false, true] {
      let data = Data("{\"reentryCompensationEnabled\":\(enabled),\"paletteMode\":\"fixed\",\"hapticsEnabled\":false}".utf8)
      defaults.set(data, forKey: RimeKeyboardPreferencesStore.storageKey)
      let preferences = store.value
      XCTAssertEqual(preferences.paletteMode, .fixed)
      XCTAssertFalse(preferences.hapticsEnabled)
      store.value = preferences
      let saved = try XCTUnwrap(defaults.data(forKey: RimeKeyboardPreferencesStore.storageKey))
      let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
      XCTAssertNil(fields["reentryCompensationEnabled"])
      XCTAssertEqual(store.value, preferences)
    }
  }

  func testSpaceSideKeysDefaultOffForFreshAndLegacyPreferences() throws {
    XCTAssertEqual(store.value.leftSpaceKey.mode, .disabled)
    XCTAssertEqual(store.value.rightSpaceKey.mode, .disabled)
    defaults.set(Data(#"{"auxiliaryKeySide":"left","auxiliaryPrefix":";","hapticsEnabled":false}"#.utf8),
                 forKey: RimeKeyboardPreferencesStore.storageKey)
    XCTAssertEqual(store.value.leftSpaceKey.mode, .disabled)
    XCTAssertEqual(store.value.rightSpaceKey.mode, .disabled)
    XCTAssertEqual(store.value.auxiliaryPrefix, ";")
    XCTAssertFalse(store.value.hapticsEnabled)
  }

  func testIndependentSpaceSideKeysPersistAndReset() {
    var preferences = store.value
    preferences.leftSpaceKey = RimeSpaceSideKey(mode: .character, character: ";")
    preferences.rightSpaceKey = RimeSpaceSideKey(mode: .auxiliary)
    store.value = preferences
    XCTAssertEqual(store.value, preferences)
    XCTAssertEqual(store.value.leftSpaceKey.input(auxiliaryPrefix: ","), ";")
    XCTAssertEqual(store.value.rightSpaceKey.input(auxiliaryPrefix: ","), ",")
    store.reset()
    XCTAssertEqual(store.value.leftSpaceKey.mode, .disabled)
    XCTAssertEqual(store.value.rightSpaceKey.mode, .disabled)
  }

  func testCustomSpaceSideKeyValidation() {
    for (input, expected) in [("；", ";"), ("Ａ", "A"), ("1", "1"), ("?", "?")] {
      XCTAssertEqual(RimeSpaceSideKey.normalizedCharacter(input), expected)
    }
    for input in ["", "ab", "\n", " ", "你好"] {
      XCTAssertNil(RimeSpaceSideKey.normalizedCharacter(input))
    }
  }

  func testFullwidthAuxiliaryPunctuationIsStoredAsASCII() throws {
    XCTAssertEqual(RimeKeyboardPreferences.normalizedAuxiliaryPrefix("；"), ";")
    XCTAssertEqual(RimeKeyboardPreferences.normalizedAuxiliaryPrefix("，"), ",")
    XCTAssertNil(RimeKeyboardPreferences.normalizedAuxiliaryPrefix("字"))
    XCTAssertNil(RimeKeyboardPreferences.normalizedAuxiliaryPrefix("ab"))
    XCTAssertEqual(RimeKeyboardPreferences(auxiliaryPrefix: "；").auxiliaryPrefix, ";")
    defaults.set(Data(#"{"auxiliaryPrefix":"；"}"#.utf8),
                 forKey: RimeKeyboardPreferencesStore.storageKey)
    XCTAssertEqual(store.value.auxiliaryPrefix, ";")
  }

  func testAValueSurvivesARoundTrip() {
    var preferences = store.value
    preferences.compositionDisplay = .preedit
    preferences.paletteMode = .fixed
    preferences.keyClickEnabled = false
    preferences.deleteRepeatInterval = 0.08
    store.value = preferences

    XCTAssertEqual(store.value, preferences)
    // A second store over the same defaults sees it, which is how the keyboard reads what the app
    // wrote.
    let again = RimeKeyboardPreferencesStore(defaults: defaults)
    XCTAssertEqual(again.value.paletteMode, .fixed)
    XCTAssertFalse(again.value.keyClickEnabled)
    XCTAssertEqual(again.value.deleteRepeatInterval, 0.08, accuracy: 0.001)
  }

  func testCorruptOrMissingDataFallsBackToTheDefaults() {
    defaults.set(Data("not json".utf8), forKey: RimeKeyboardPreferencesStore.storageKey)
    XCTAssertEqual(store.value, .standard)

    // A field added later is a missing key, which decodes to its default rather than throwing away
    // the whole blob.
    defaults.set(Data(#"{"paletteMode":"fixed"}"#.utf8),
                 forKey: RimeKeyboardPreferencesStore.storageKey)
    XCTAssertEqual(store.value.compositionDisplay, .rawInput)
    XCTAssertEqual(store.value.paletteMode, .fixed)
    XCTAssertTrue(store.value.hapticsEnabled, "the missing fields keep their defaults")
  }

  func testDoublePinyinMarkedTextUsesSelectedRepresentation() {
    let output = RimeOutput(handled: true, commit: nil,
      composition: RimeCompositionInfo(preedit: "ni hao", cursorPosition: 6,
                                       selectionStart: 0, selectionEnd: 6),
      page: nil, status: nil, input: "nihc")
    var preferences = RimeKeyboardPreferences.standard
    XCTAssertEqual(preferences.markedText(for: output), "nihc")
    preferences.compositionDisplay = .preedit
    XCTAssertEqual(preferences.markedText(for: output), "ni hao")

    let committed = RimeOutput(handled: true, commit: "你好", composition: nil,
                               page: nil, status: nil, input: "")
    for mode in RimeKeyboardPreferences.CompositionDisplay.allCases {
      preferences.compositionDisplay = mode
      XCTAssertTrue((preferences.markedText(for: committed) ?? "").isEmpty)
    }
  }

  func testRawDisplayUsesOnlyBoundariesThatPreserveTheTypedSpelling() {
    for (input, preedit, expected) in [
      ("nihc", "ni hc", "ni hc"),
      ("nihao", "ni hao", "ni hao"),
      ("ni'hao", "ni'hao", "ni'hao"),
      ("ni hao", "ni hao", "ni hao"),
      ("nihc", "ni hao", "nihc"),
      ("nihc", "你 hc", "nihc"),
      ("abc", "abc hint", "abc"),
      ("n", "n", "n"),
    ] {
      let output = RimeOutput(handled: true, commit: nil,
        composition: RimeCompositionInfo(preedit: preedit, cursorPosition: preedit.utf8.count,
                                         selectionStart: 0, selectionEnd: preedit.utf8.count),
        page: nil, status: nil, input: input)
      XCTAssertEqual(RimeKeyboardPreferences.standard.markedText(for: output), expected)
      XCTAssertEqual(output.input, input)
      XCTAssertNil(output.commit)
    }
  }

  func testResetRestoresTheDefaults() {
    var preferences = store.value
    preferences.calloutEnabled = false
    store.value = preferences
    XCTAssertFalse(store.value.calloutEnabled)
    store.reset()
    XCTAssertEqual(store.value, .standard)
  }

  func testExpandedFlypySyllablesMapToOriginalKeysWithoutGuessingPairs() {
    for schemaID in ["pinyin_flypy", "double_pinyin_flypy"] {
      for (input, preedit, expected) in [
        ("nihc", "ni hao", "ni hc"),
        ("nihcaa", "ni hao a", "ni hc aa"),
        ("nihcaa", "ni hao aa", "ni hc aa"),
        ("nihca", "ni hao a", "ni hc a"),
        ("nhc", "ni hao", "n hc"),
        ("viui", "zhi shi", "vi ui"),
        ("jvlt", "ju lüe", "jv lt"),
        ("ahgo", "ang guo", "ah go"),
        ("aihc", "ai hao", "ai hc"),
        ("adhc", "ai hao", "ad hc"),
        ("nihc", "你 hao", "nihc"),
        ("abcdef", "abc def", "abc def"),
        ("nihcaa", "ni hao prompt", "nihcaa"),
        ("aaa", "a a", "aaa"),
        ("nhc", "ni wrong", "nhc"),
      ] {
        let output = RimeOutput(handled: true, commit: nil,
          composition: RimeCompositionInfo(preedit: preedit, cursorPosition: preedit.utf8.count,
                                           selectionStart: 0, selectionEnd: preedit.utf8.count),
          page: nil,
          status: RimeStatusSnapshot(schemaID: schemaID, schemaName: "Flypy", isDisabled: false,
                                    isComposing: true, isAsciiMode: false, isFullShape: false,
                                    isSimplified: true, isTraditional: false, isAsciiPunctuation: false),
          input: input)
        XCTAssertEqual(RimeKeyboardPreferences.standard.markedText(for: output), expected, input)
        XCTAssertEqual(output.input, input)
        XCTAssertNil(output.commit)
        XCTAssertEqual(RimeKeyboardPreferences(compositionDisplay: .preedit).markedText(for: output), preedit)
      }
    }
    XCTAssertNil(RimePreeditSegmentation.syllables(input: "nihc", preedit: "ni hao", schemaID: "other"))
  }

  func testThePreferencesDescribeTheFeedbackPolicy() {
    var preferences = store.value
    preferences.deleteRepeatDelay = 0.6
    preferences.deleteRepeatInterval = 0.12
    let feedback = preferences.feedback
    XCTAssertEqual(feedback.deleteRepeatDelay, 0.6)
    XCTAssertEqual(feedback.deleteRepeatInterval, 0.12)
    XCTAssertEqual(RimeKeyFeedbackPolicy.deleteRepeatSchedule(feedback: feedback).delay, 0.6,
                   "the view reads the policy, not a constant")
  }

  func testTurningTheCalloutOffIsPartOfThePolicy() {
    var preferences = store.value
    XCTAssertTrue(preferences.allowsCallout(isPhoneClass: true))
    XCTAssertFalse(preferences.allowsCallout(isPhoneClass: false),
                   "an iPad-class keyboard has no callout regardless")
    preferences.calloutEnabled = false
    XCTAssertFalse(preferences.allowsCallout(isPhoneClass: true))
  }

  func testTheAppGroupStoreIsAvailableOrExplicitlyNot() throws {
    // The app group may not resolve in a test process; what matters is that the API says so rather
    // than inventing a store that silently writes somewhere else.
    let shared = RimeKeyboardPreferencesStore.appGroup(databaseID: suite)
    XCTAssertNotNil(shared, "a suite that exists must resolve")
    shared?.value = .standard
    XCTAssertEqual(shared?.value, .standard)
  }
}
