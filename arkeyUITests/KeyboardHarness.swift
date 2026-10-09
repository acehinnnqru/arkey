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
  /// True when the keyboard on screen is Arkey's — and only Arkey's.
  ///
  /// Two earlier versions of this were wrong in ways worth remembering. 删除 is not enough: the system's
  /// Chinese keyboard has one too. Neither is "the bar's view exists": the extension's view stays in the
  /// hierarchy after the input mode moves on, so exists was true of a keyboard no longer on screen. Even the
  /// keys and candidates are not enough — the system Pinyin keyboard has the same letters and offers the same
  /// 你好 for nihao, so a test can be green while typing on the system keyboard.
  ///
  /// What is enough is a *hittable* line of text no other keyboard shows: this bar's status line, which names
  /// the container and the full-access state.
  func arkeyKeyboardIsUp(_ app: XCUIApplication) -> Bool {
    let status = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Arkey 就绪'")).firstMatch
    return status.exists && status.isHittable
  }

  /// A control inside the keyboard, whatever element type the system decides it is: the bar's chevrons come
  /// back as neither a plain Button nor a Key consistently, so they are matched by identifier alone.
  func keyboardControl(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: label).firstMatch
  }

  /// A key by its accessibility *label*, which is what the keyboard sets: letter keys answer to `app.keys["Q"]`
  /// and the delete key's label is 删除. `keyboardControl` looks identifiers up instead, and the keyboard has
  /// none — round 189 found the delete step of the shift test failing for that reason alone: it never tapped a
  /// key, and reported "delete never took the letter back".
  func keyboardKey(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    // Scoped to the keyboard first: the app's own screens have buttons labelled 删除, and an unscoped lookup can
    // find one of those and tap it (which is what the first version did). The keyboard's keys answer to the
    // label they show — "Q" for a letter, "⌫" for delete — not to their VoiceOver label.
    // Arkey's keys are not inside the system's `keyboards` container, and `app.keys` is the element type that
    // excludes the app's own buttons — which is the distinction that matters, since 配置库 has a 删除 button too.
    let byKey = app.keys[label]
    if byKey.exists { return byKey }
    return app.descendants(matching: .key)
      .matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  /// Cycles the input mode until Arkey's bar is on screen *and stays there*: a single look is not enough,
  /// because the extension's view is hittable for a moment while it fades out, and a loop that trusts that
  /// first look walks on with the system keyboard in front of it (which is how two of these tests failed
  /// while reporting the wrong thing).
  func switchToArkey(_ app: XCUIApplication) {
    for _ in 1...6 {
      if arkeyKeyboardIsUp(app) {
        Thread.sleep(forTimeInterval: 1.2)
        if arkeyKeyboardIsUp(app) { return }
      }
      let globe = app.buttons.matching(
        NSPredicate(format: "label IN %@", ["Next keyboard", "下一个键盘"])).firstMatch
      guard globe.exists else { break }
      globe.tap()
      Thread.sleep(forTimeInterval: 2.0)
    }
  }
}
