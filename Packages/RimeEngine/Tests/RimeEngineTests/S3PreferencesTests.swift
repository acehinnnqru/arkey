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

  func testAFreshStoreHandsBackTheShippedDefaults() {
    XCTAssertEqual(store.value, .standard)
    XCTAssertEqual(store.value.paletteMode, .followHost, "the material path is the recommendation")
    XCTAssertTrue(store.value.keyClickEnabled)
    XCTAssertTrue(store.value.calloutEnabled)
    XCTAssertEqual(store.value.deleteRepeatDelay, 0.5)
    XCTAssertEqual(store.value.deleteRepeatInterval, 0.1)
  }

  func testAValueSurvivesARoundTrip() {
    var preferences = store.value
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
    XCTAssertEqual(store.value.paletteMode, .fixed)
    XCTAssertTrue(store.value.hapticsEnabled, "the missing fields keep their defaults")
  }

  func testResetRestoresTheDefaults() {
    var preferences = store.value
    preferences.calloutEnabled = false
    store.value = preferences
    XCTAssertFalse(store.value.calloutEnabled)
    store.reset()
    XCTAssertEqual(store.value, .standard)
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
