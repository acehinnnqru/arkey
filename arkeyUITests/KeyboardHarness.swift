import XCTest

/// The plumbing the keyboard tests share: getting the extension installed, getting to it, and finding things in
/// Settings. It lives here rather than in each test because the Settings walk is long and the details (the
/// keyboard's row is "ARKeyboard — arkey"; the list entry is "arkey") are the kind that rot.
extension XCTestCase {
  /// Adds the keyboard if the simulator does not have it yet. Idempotent: a simulator keeps it once added.
  func enableThirdPartyKeyboard(file: StaticString = #filePath, line: UInt = #line) {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 30), "Settings did not open",
                  file: file, line: line)
    Thread.sleep(forTimeInterval: 1.0)

    tapSetting(settings, "General"); Thread.sleep(forTimeInterval: 0.6)
    tapSetting(settings, "Keyboard"); Thread.sleep(forTimeInterval: 0.6)
    tapSetting(settings, "Keyboards"); Thread.sleep(forTimeInterval: 0.6)

    let added = settings.cells.containing(NSPredicate(format: "label CONTAINS[c] 'arkey'")).firstMatch
    if added.waitForExistence(timeout: 3) {
      settings.terminate()
      return
    }
    tapSetting(settings, "Add New Keyboard"); Thread.sleep(forTimeInterval: 1.0)
    let entry = settings.cells.containing(NSPredicate(format: "label CONTAINS[c] 'arkey'")).firstMatch
    if entry.waitForExistence(timeout: 5) {
      entry.tap()
      Thread.sleep(forTimeInterval: 1.2)
      // The full-access sheet, when it appears: leave it as it is (the keyboard works without it — it keeps
      // its state in its own container) and go back to the list.
      tapSetting(settings, "Keyboards")
    }
    settings.terminate()
  }

  @discardableResult
  func tapSetting(_ app: XCUIApplication, _ label: String) -> Bool {
    let cell = app.cells.containing(.staticText, identifier: label).firstMatch
    if cell.exists { cell.tap(); return true }
    let button = app.buttons[label].firstMatch
    if button.exists { button.tap(); return true }
    return false
  }

  /// Launches the app, focuses the field and switches the input mode to Arkey with the globe — which is the
  /// key the system puts on every keyboard. "Arkey is up" is detected by a key only this keyboard has.
  @discardableResult
  func launchAppWithArkeyKeyboard() -> (app: XCUIApplication, field: XCUIElement) {
    let app = XCUIApplication()
    app.launch()
    let field = app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 30), "the app's text field never appeared")
    field.tap()
    Thread.sleep(forTimeInterval: 1.5)
    switchToArkey(app)
    XCTAssertTrue(arkeyKeyboardIsUp(app),
                  "the Arkey keyboard did not come up: keys "
                    + app.keys.allElementsBoundByIndex.prefix(10).map { $0.label }.joined(separator: " ")
                    + " / buttons "
                    + app.buttons.allElementsBoundByIndex.prefix(10).map { $0.label }.joined(separator: " "))
    return (app, field)
  }

  /// True when the keyboard on screen is Arkey's. 删除 is not enough to go on: the system's Chinese keyboard
  /// has a 删除 key too, so the first version of this walked straight past Arkey and typed on the system one.
  /// What only this keyboard has is its own bar, which shows the engine's status line when it is idle.
  /// Hittable, not merely present: the extension's view can stay in the hierarchy after the input mode moves
  /// on, and "exists" was true of a keyboard that was no longer on screen — which is how the first version of
  /// this typed on the system keyboard while believing it was on Arkey's. The bar's expand chevron is a button
  /// only this keyboard has, and it is always enabled.
  func arkeyKeyboardIsUp(_ app: XCUIApplication) -> Bool {
    if app.buttons["展开候选面板"].firstMatch.isHittable { return true }
    return app.buttons["表情符号"].firstMatch.isHittable && app.keys["删除"].firstMatch.isHittable
  }

  func switchToArkey(_ app: XCUIApplication) {
    for _ in 1...5 {
      if arkeyKeyboardIsUp(app) { return }
      let globe = app.buttons["Next keyboard"].firstMatch
      guard globe.exists else { break }
      globe.tap()
      Thread.sleep(forTimeInterval: 1.8)
    }
  }
}
