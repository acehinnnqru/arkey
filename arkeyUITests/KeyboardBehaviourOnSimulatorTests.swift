import XCTest

/// The installed keyboard's own controls, on a simulator: the layer keys, shift, delete, the key that advances
/// the input mode, and the status line the keyboard shows about itself.
///
/// These are the seams the unit tests cannot reach — they drive the extension's views directly, not the
/// keyboard the system hosts — and they are exactly what a device run would otherwise be the first to try.
///
/// Every interaction here is retried with the input mode re-established first. That is not belt-and-braces: the
/// system can move the input mode under the test (and the extension's view is hittable for a moment while it
/// fades out), so a single attempt measures the race as often as it measures the keyboard.
final class KeyboardBehaviourOnSimulatorTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// The keyboard the system hosts, in a state where Arkey's bar is really on screen.
  private func onArkey<T>(_ app: XCUIApplication, _ body: () -> T?) -> T? {
    for _ in 1...3 {
      switchToArkey(app)
      guard arkeyKeyboardIsUp(app) else { continue }
      if let value = body() { return value }
    }
    return nil
  }

  func testTheLayerKeysChangeTheInstalledKeyboard() throws {
    enableThirdPartyKeyboard()
    let (app, _) = launchAppWithArkeyKeyboard()

    let digits = onArkey(app) { () -> Bool? in
      let key = keyboardControl(app, "数字")
      guard key.isHittable else { return nil }
      key.tap()
      Thread.sleep(forTimeInterval: 0.6)
      return app.keys["1"].exists && !app.keys["q"].exists ? true : nil
    }
    XCTAssertTrue(digits ?? false,
                  "数字 never brought up the digits layer on the installed keyboard: keys "
                    + app.keys.allElementsBoundByIndex.prefix(14).map { $0.label }.joined(separator: " "))

    let letters = onArkey(app) { () -> Bool? in
      let key = keyboardControl(app, "字母")
      guard key.isHittable else { return nil }
      key.tap()
      Thread.sleep(forTimeInterval: 0.6)
      return app.keys["q"].exists ? true : nil
    }
    XCTAssertTrue(letters ?? false, "字母 never brought the letters back")
  }

  func testShiftAndDeleteOnTheInstalledKeyboard() throws {
    enableThirdPartyKeyboard()
    let (app, field) = launchAppWithArkeyKeyboard()

    let upper = onArkey(app) { () -> Bool? in
      let shift = keyboardControl(app, "shift")
      guard shift.isHittable else { return nil }
      shift.tap()
      Thread.sleep(forTimeInterval: 0.6)
      return app.keys["Q"].exists ? true : nil
    }
    XCTAssertTrue(upper ?? false,
                  "shift never upper-cased the installed keyboard: keys "
                    + app.keys.allElementsBoundByIndex.prefix(12).map { $0.label }.joined(separator: " "))

    // Type the upper-case letter and take it back; the composition follows the keys.
    let typed = onArkey(app) { () -> String? in
      let key = app.keys["Q"].firstMatch
      guard key.isHittable else { return nil }
      key.tap()
      Thread.sleep(forTimeInterval: 0.6)
      let value = ((field.value as? String) ?? "").filter { !$0.isWhitespace }
      return value.contains("Q") ? value : nil
    }
    XCTAssertNotNil(typed, "the typed letter never reached the field: ["
                    + (((field.value as? String) ?? "")) + "]")

    let deleted = onArkey(app) { () -> String? in
      let key = keyboardControl(app, "删除")
      guard key.isHittable else { return nil }
      key.tap()
      Thread.sleep(forTimeInterval: 0.6)
      let value = ((field.value as? String) ?? "").filter { !$0.isWhitespace }
      return value.contains("Q") ? nil : value
    }
    XCTAssertNotNil(deleted, "delete never took the letter back: ["
                    + (((field.value as? String) ?? "")) + "]")
  }

  /// S1 §9's diagnostics, in the keyboard the system hosts: the bar says which container the extension got and
  /// whether full access was granted, which is the line the device run reads out. It is also the proof that the
  /// other tests in this file are on Arkey rather than on the system's Chinese keyboard.
  func testTheInstalledKeyboardSaysWhichContainerItIsUsing() throws {
    enableThirdPartyKeyboard()
    let (app, _) = launchAppWithArkeyKeyboard()

    let status = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Arkey 就绪'")).firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 10), "the bar shows no status line")
    let line = status.label
    XCTAssertTrue(line.contains("共享容器") || line.contains("扩展容器"),
                  "the status line does not name the container: [" + line + "]")
    XCTAssertTrue(line.contains("完全访问开") || line.contains("完全访问关"),
                  "the status line does not say whether full access is granted: [" + line + "]")
    XCTAssertTrue(line.contains("内置数据"),
                  "nothing is deployed in this container, so the line should name the bundled fallback: ["
                    + line + "]")
  }
}