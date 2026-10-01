import XCTest

/// The real keyboard, on a simulator: the extension is enabled in Settings, the app's field is focused, the
/// keyboard is switched to Arkey with its own globe key, and then it types.
///
/// This is the closest thing to the device run that exists in this repository. Everything else drives the
/// extension's views directly or the engine underneath them; this drives the *installed keyboard*, through the
/// system, into a real text field — and reads the sentence back out of the field.
final class KeyboardTypingOnSimulatorTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// Adds the keyboard if the simulator does not have it yet. Idempotent: a simulator keeps it once added, and
  /// the second run finds it in the list and leaves.
  private func enableKeyboardIfNeeded() {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 30), "Settings did not open")
    Thread.sleep(forTimeInterval: 1.0)

    tap(settings, "General"); Thread.sleep(forTimeInterval: 0.6)
    tap(settings, "Keyboard"); Thread.sleep(forTimeInterval: 0.6)
    tap(settings, "Keyboards"); Thread.sleep(forTimeInterval: 0.6)
    // Already installed? A simulator keeps the keyboard once added, and the row says "ARKeyboard — arkey", so
    // the check is a contains-match rather than the name on its own.
    let added = settings.cells.containing(NSPredicate(format: "label CONTAINS[c] 'arkey'")).firstMatch
    if added.waitForExistence(timeout: 3) {
      settings.terminate()
      return
    }
    tap(settings, "Add New Keyboard"); Thread.sleep(forTimeInterval: 1.0)
    let entry = settings.cells.containing(NSPredicate(format: "label CONTAINS[c] 'arkey'")).firstMatch
    if entry.waitForExistence(timeout: 5) {
      entry.tap()
      Thread.sleep(forTimeInterval: 1.2)
      // The full-access sheet, when it appears: leave it as it is (the keyboard works without it — it keeps
      // its state in its own container) and go back to the list.
      tap(settings, "Keyboards")
    }
    settings.terminate()
  }

  @discardableResult
  private func tap(_ app: XCUIApplication, _ label: String) -> Bool {
    let cell = app.cells.containing(.staticText, identifier: label).firstMatch
    if cell.exists { cell.tap(); return true }
    let button = app.buttons[label].firstMatch
    if button.exists { button.tap(); return true }
    return false
  }

  /// Switches the input mode to Arkey with the globe, which is the key the system puts on every keyboard —
  /// and which the extension also uses for its own 中/英 slot. Detected by a key only this keyboard has.
  private func switchToArkey(_ app: XCUIApplication) {
    for _ in 1...4 {
      if app.keys["删除"].exists || app.keys["换行"].exists { return }
      let globe = app.buttons["Next keyboard"].firstMatch
      guard globe.exists else { break }
      globe.tap()
      Thread.sleep(forTimeInterval: 1.5)
    }
  }

  func testTheRealKeyboardTypesNihaoIntoTheField() throws {
    enableKeyboardIfNeeded()

    let app = XCUIApplication()
    app.launch()
    let field = app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 30), "the app's text field never appeared")
    field.tap()
    Thread.sleep(forTimeInterval: 1.5)
    switchToArkey(app)
    XCTAssertTrue(app.keys["删除"].waitForExistence(timeout: 10),
                  "the Arkey keyboard did not come up: the keys on screen are "
                    + app.keys.allElementsBoundByIndex.prefix(12).map { $0.label }.joined(separator: " "))

    for letter in ["n", "i", "h", "a", "o"] {
      let key = app.keys[letter].firstMatch
      XCTAssertTrue(key.waitForExistence(timeout: 5), "no " + letter + " key")
      key.tap()
    }

    // The keyboard is composing: the field holds the marked text the engine produced.
    // Whitespace-insensitive: the preedit's separators are not the ASCII space (the engine divides the
    // syllables with its own), and the point is the letters.
    let marked = (field.value as? String) ?? ""
    let compact = String(marked.filter { !$0.isWhitespace })
    XCTAssertTrue(compact.contains("nihao"),
                  "the field does not hold the composition: [" + marked + "]")

    // The bar's candidates are exposed as text, not as buttons (the cell wraps a label), so the first one is
    // tapped where it is.
    let candidate = app.staticTexts["你好"].firstMatch
    XCTAssertTrue(candidate.waitForExistence(timeout: 10),
                  "the candidate bar shows nothing: "
                    + app.staticTexts.allElementsBoundByIndex.prefix(12).map { $0.label }
                      .joined(separator: " | "))
    candidate.tap()
    Thread.sleep(forTimeInterval: 1.5)

    let text = (field.value as? String) ?? ""
    XCTAssertTrue(text.contains("你好"), "the field says: [" + text + "]")
  }
}
