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

    // Round 189: this step reported "delete never took the letter back" while the key it tapped was the wrong
    // element (the app's own 删除 button, not the keyboard's key). The state goes into the message, because a
    // failing assertion is the only thing from the test process that reaches the build log.
    let deleteKey = keyboardKey(app, "删除")
    XCTAssertTrue(deleteKey.exists && deleteKey.isHittable,
                  "the delete key is not reachable: "
                    + app.keys.allElementsBoundByIndex.prefix(40).map { $0.label }.joined(separator: " "))
    let before = ((field.value as? String) ?? "").filter { !$0.isWhitespace }
    deleteKey.tap()
    Thread.sleep(forTimeInterval: 0.8)
    let afterOne = ((field.value as? String) ?? "").filter { !$0.isWhitespace }
    let bar = app.staticTexts.allElementsBoundByIndex.prefix(6).map { $0.label }.joined(separator: " / ")
    XCTAssertFalse(afterOne.contains("Q"),
                   "delete left the letter: before=[\(before)] after=[\(afterOne)] bar=[\(bar)]")
  }

  func testKeyboardSurvivesAppSwitchAndDismissal() throws {
    enableThirdPartyKeyboard()
    let (app, field) = launchAppWithArkeyKeyboard()
    let enter = app.keys.matching(NSPredicate(format: "label IN %@", ["换行", "return", "Return"])).firstMatch
    XCTAssertTrue(enter.waitForExistence(timeout: 10))
    let before = enter.frame
    let surface = keyboardControl(app, "Arkey.keyboardSurface")
    XCTAssertTrue(surface.waitForExistence(timeout: 10))
    let firstSurface = surface.frame
    let firstRowTop = app.keys["q"].frame.minY
    XCTAssertEqual(firstRowTop - firstSurface.minY, 52, accuracy: 1,
                   "the full reference candidate slot must be present on first display")
    XCTAssertLessThanOrEqual(field.frame.maxY, app.keys["q"].frame.minY)

    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let status = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Arkey 就绪'")).firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertTrue(enter.waitForExistence(timeout: 10))
    XCTAssertEqual(enter.frame.minY, before.minY, accuracy: 1)

    // Navigation resigns the editor; returning and focusing it presents the same extension again.
    app.navigationBars.buttons["键盘"].tap()
    XCTAssertTrue(app.navigationBars["键盘预览"].waitForExistence(timeout: 10))
    let dismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == false"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    switchToArkey(app)
    XCTAssertTrue(arkeyKeyboardIsUp(app))
    XCTAssertEqual(enter.frame.minY, before.minY, accuracy: 1)
    XCTAssertEqual(surface.frame.minY, firstSurface.minY, accuracy: 1,
                   "the keyboard top must stay in place after navigation")
    XCTAssertEqual(surface.frame.height, firstSurface.height, accuracy: 1,
                   "the host must reserve the same keyboard height after navigation")
    XCTAssertEqual(app.keys["q"].frame.minY, firstRowTop, accuracy: 1)
    XCTAssertLessThanOrEqual(field.frame.maxY, surface.frame.minY,
                            "the editor must stay above the entire keyboard after navigation")
  }

  func testKeyboardRecoversDictionarySessionAfterHostBackgrounding() throws {
    enableThirdPartyKeyboard()
    let (app, field) = launchAppWithArkeyKeyboard()
    let ready = app.staticTexts.containing(NSPredicate(
      format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Arkey 就绪", "Arkey ready")).firstMatch
    XCTAssertTrue(ready.waitForExistence(timeout: 10))

    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(ready.waitForExistence(timeout: 10), "Host activation must reopen the dictionary session")
    for letter in ["n", "i", "h", "a", "o"] { app.keys[letter].tap() }
    let candidate = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "你好")).firstMatch
    XCTAssertTrue(candidate.waitForExistence(timeout: 10), "Resumed input must produce Chinese candidates")
    candidate.tap()
    XCTAssertTrue(((field.value as? String) ?? "").contains("你好"))
  }

  /// This checks settled extension geometry. It does not verify the host's
  /// outer height or exclude a visible spike during the switching animation.
  func testInputModeSwitchDoesNotIncreaseKeyboardHeight() throws {
    enableThirdPartyKeyboard()
    let (app, field) = launchAppWithArkeyKeyboard()
    let surface = keyboardControl(app, "Arkey.keyboardSurface")
    XCTAssertTrue(surface.waitForExistence(timeout: 10))
    let first = surface.frame
    let firstRow = app.keys["q"].frame
    let firstCapture = XCTAttachment(screenshot: app.screenshot())
    firstCapture.name = "Keyboard material before input-mode switching"
    firstCapture.lifetime = .keepAlways
    add(firstCapture)
    for index in 0..<3 {
      let globe = app.buttons.matching(
        NSPredicate(format: "label IN %@", ["Next keyboard", "下一个键盘"])).firstMatch
      XCTAssertTrue(globe.isHittable, "the host keyboard switch button must be reachable")
      globe.tap()
      let away = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "isHittable == false"), object: surface)
      XCTAssertEqual(XCTWaiter.wait(for: [away], timeout: 5), .completed)
      switchToArkey(app)
      XCTAssertTrue(arkeyKeyboardIsUp(app))
      XCTAssertEqual(surface.frame.height, first.height, accuracy: 1)
      XCTAssertEqual(surface.frame.minY, first.minY, accuracy: 1)
      XCTAssertEqual(app.keys["q"].frame.minY, firstRow.minY, accuracy: 1)
      XCTAssertLessThanOrEqual(field.frame.maxY, surface.frame.minY,
                              "the editor must avoid the keyboard after changing input modes")
      let capture = XCTAttachment(screenshot: app.screenshot())
      capture.name = "Keyboard material after input-mode switch \(index + 1)"
      capture.lifetime = .keepAlways
      add(capture)
    }
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

  /// A custom keyboard fills the frame the system hands it, minus the strip the system owns. The device
  /// screenshot in round 189 showed a band of empty backing under the last row, and the user said why: iOS
  /// already reserves the height of its own bottom row (the globe key) and the home-indicator area, and the
  /// layout was adding the system keyboard's measured 80.3 pt bottom inset on top of that. Measured on an
  /// iPhone 17 Pro: 144.3 pt of space under the last row before, 64.0 pt after — which round 191 read again:
  /// that 64.0 was the strip *minus* the 11 pt the frame was clipping off the bottom row, measured from the
  /// keys' model position, and a clip does not move it. A ceiling on the band cannot see a clip, so the
  /// frame-and-views agreement is pinned by
  /// `KeyboardControllerTests.testTheFrameTheExtensionAsksForHoldsEveryKey`; this stays as the band's guard.
  func testTheKeysReachTheBottomOfTheSystemStrip() throws {
    enableThirdPartyKeyboard()
    let (app, _) = launchAppWithArkeyKeyboard()
    guard onArkey(app, { arkeyKeyboardIsUp(app) ? true : nil }) != nil else {
      XCTFail("the keyboard never came up")
      return
    }
    let enter = app.keys.matching(NSPredicate(format: "label IN %@", ["换行", "return", "Return"])).firstMatch
    XCTAssertTrue(enter.waitForExistence(timeout: 5))
    let window = app.windows.firstMatch
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Keyboard host background"
    capture.lifetime = .keepAlways
    add(capture)
    let gap = window.frame.maxY - enter.frame.maxY
    XCTAssertEqual(gap, 80, accuracy: 2,
                   "the final key row must match the native keyboard's bottom strip")
    let first = app.keys["q"].firstMatch
    XCTAssertEqual(first.frame.minY, window.frame.maxY - 80 - 213, accuracy: 2,
                   "the letter rows must match the native reference's vertical position")
    XCTAssertLessThan(gap, 90,
                      "the last key row stops " + String(format: "%.0f", gap) + " pt above the window, more than "
                        + "the system's own strip (key ends at " + String(format: "%.0f", enter.frame.maxY)
                        + ", window at " + String(format: "%.0f", window.frame.maxY) + ")")
  }
}
