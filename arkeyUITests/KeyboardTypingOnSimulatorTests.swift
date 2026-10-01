import XCTest

/// The real keyboard, on a simulator: the extension is enabled in Settings, the app's field is focused, the
/// keyboard is switched to Arkey with the globe, and then it types.
///
/// This is the closest thing to the device run that exists in this repository. Everything else drives the
/// extension's views directly or the engine underneath them; this drives the *installed keyboard*, through the
/// system, into a real text field — and reads the sentence back out of the field.
final class KeyboardTypingOnSimulatorTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testTheRealKeyboardTypesNihaoIntoTheField() throws {
    enableThirdPartyKeyboard()
    let (app, field) = launchAppWithArkeyKeyboard()

    for letter in ["n", "i", "h", "a", "o"] {
      let key = app.keys[letter].firstMatch
      XCTAssertTrue(key.waitForExistence(timeout: 5), "no " + letter + " key")
      key.tap()
    }

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
