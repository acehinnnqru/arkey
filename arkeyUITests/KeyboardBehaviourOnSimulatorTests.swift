import XCTest

/// The installed keyboard's own controls, on a simulator: the layer keys, shift, delete and the key that
/// advances the input mode.
///
/// These are the seams the unit tests cannot reach — they drive the extension's views directly, not the
/// keyboard the system hosts — and they are exactly what a device run would otherwise be the first to try.
final class KeyboardBehaviourOnSimulatorTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testTheLayerKeysChangeTheInstalledKeyboard() throws {
    enableThirdPartyKeyboard()
    let (app, _) = launchAppWithArkeyKeyboard()
    XCTAssertTrue(app.keys["q"].exists, "the letters layer is not showing to begin with")

    app.keys["数字"].firstMatch.tap()
    XCTAssertTrue(app.keys["1"].waitForExistence(timeout: 5),
                  "the numbers layer did not appear: "
                    + app.keys.allElementsBoundByIndex.prefix(14).map { $0.label }.joined(separator: " "))
    XCTAssertFalse(app.keys["q"].exists, "the letters are still on the numbers layer")

    // The letters key draws "ABC" and calls itself 字母 (the engine's accessibility label), which is the
    // name the system announces and the one a query finds.
    app.keys["字母"].firstMatch.tap()
    XCTAssertTrue(app.keys["q"].waitForExistence(timeout: 5),
                  "the letters key did not bring the letters back: "
                    + app.keys.allElementsBoundByIndex.prefix(14).map { $0.label }.joined(separator: " "))
  }

  func testShiftAndDeleteOnTheInstalledKeyboard() throws {
    enableThirdPartyKeyboard()
    let (app, field) = launchAppWithArkeyKeyboard()

    // A control can be exposed as a button or as a key depending on how the system hosts the keyboard, so
    // both are tried rather than assuming one.
    let shift = app.buttons["shift"].firstMatch.exists ? app.buttons["shift"].firstMatch
                                                       : app.keys["shift"].firstMatch
    XCTAssertTrue(shift.waitForExistence(timeout: 5),
                  "no shift key: buttons "
                    + app.buttons.allElementsBoundByIndex.prefix(14).map { $0.label }.joined(separator: " | "))
    shift.tap()
    XCTAssertTrue(app.keys["Q"].waitForExistence(timeout: 5),
                  "shift did not upper-case the keyboard: "
                    + app.keys.allElementsBoundByIndex.prefix(12).map { $0.label }.joined(separator: " "))

    // Type one upper-case letter and take it back with delete: the composition follows the keys.
    app.keys["Q"].firstMatch.tap()
    Thread.sleep(forTimeInterval: 0.6)
    let typed = ((field.value as? String) ?? "").filter { !$0.isWhitespace }
    XCTAssertTrue(typed.contains("Q"), "the field does not hold the typed letter: [" + typed + "]")

    app.keys["删除"].firstMatch.tap()
    Thread.sleep(forTimeInterval: 0.6)
    let deleted = ((field.value as? String) ?? "").filter { !$0.isWhitespace }
    XCTAssertFalse(deleted.contains("Q"), "delete did not take it back: [" + deleted + "]")
  }

  /// The emoji slot's key is D5's decision: it advances to the next input mode, which is where the system
  /// emoji keyboard lives. The one device check that decision was waiting for is this — does the mode move.
  func testTheEmojiKeyAdvancesTheInputMode() throws {
    enableThirdPartyKeyboard()
    let (app, _) = launchAppWithArkeyKeyboard()

    let emoji = app.buttons["表情符号"].firstMatch.exists ? app.buttons["表情符号"].firstMatch
                                                         : app.keys["表情符号"].firstMatch
    XCTAssertTrue(emoji.waitForExistence(timeout: 5),
                  "no emoji key: buttons "
                    + app.buttons.allElementsBoundByIndex.prefix(14).map { $0.label }.joined(separator: " | "))
    emoji.tap()
    let left = NSPredicate(format: "exists == false")
    expectation(for: left, evaluatedWith: app.keys["删除"].firstMatch, handler: nil)
    waitForExpectations(timeout: 10)

    // Come back: the globe cycles the installed keyboards, and Arkey is one of them.
    switchToArkey(app)
    XCTAssertTrue(app.keys["删除"].waitForExistence(timeout: 10),
                  "did not get back to the Arkey keyboard: "
                    + app.keys.allElementsBoundByIndex.prefix(12).map { $0.label }.joined(separator: " "))
  }


}