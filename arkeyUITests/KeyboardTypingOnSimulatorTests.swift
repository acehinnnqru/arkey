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

  func testReturnCommitsListWithoutANewlineUntilPressedAgain() throws {
    enableThirdPartyKeyboard()
    let (app, field) = launchAppWithArkeyKeyboard()
    let initial = (field.value as? String) ?? ""

    for letter in ["l", "i", "s", "t"] {
      let key = app.keys[letter].firstMatch
      XCTAssertTrue(key.waitForExistence(timeout: 5), "no " + letter + " key")
      key.tap()
    }

    let enter = app.keys.matching(
      NSPredicate(format: "label IN %@", ["换行", "return", "Return"])).firstMatch
    XCTAssertTrue(enter.waitForExistence(timeout: 5))
    for suffix in ["list", "list\n"] {
      enter.tap()
      let matches = NSPredicate { _, _ in
        (field.value as? String) == initial + suffix
      }
      let updated = XCTNSPredicateExpectation(predicate: matches, object: field)
      XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed,
                     "Return produced unexpected text: " + String(reflecting: field.value))
    }
  }

  func testFourBackspacesRemoveAllOfNihc() throws {
    enableThirdPartyKeyboard()
    let (app, field) = launchAppWithArkeyKeyboard()
    let initial = (field.value as? String) ?? ""

    for letter in ["n", "i", "h", "c"] {
      let key = app.keys[letter].firstMatch
      XCTAssertTrue(key.waitForExistence(timeout: 5), "no " + letter + " key")
      key.tap()
    }

    func assertSuffix(_ suffix: String) {
      let expected = String((initial + suffix).filter { !$0.isWhitespace })
      let matches = NSPredicate { _, _ in
        String(((field.value as? String) ?? "").filter { !$0.isWhitespace }) == expected
      }
      expectation(for: matches, evaluatedWith: field)
      waitForExpectations(timeout: 5)
    }

    assertSuffix("nihc")
    for remaining in ["nih", "ni", "n", ""] {
      keyboardKey(app, "删除").tap()
      assertSuffix(remaining)
    }
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

  func testExpandedCandidateScrollEdgesRemainReadable() throws {
    enableThirdPartyKeyboard()
    let (app, _) = launchAppWithArkeyKeyboard()
    for letter in ["n", "i"] {
      let key = app.keys[letter].firstMatch
      XCTAssertTrue(key.waitForExistence(timeout: 5))
      key.tap()
    }
    let expand = keyboardControl(app, "展开候选面板")
    XCTAssertTrue(expand.waitForExistence(timeout: 5))
    expand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(keyboardControl(app, "收起候选面板").waitForExistence(timeout: 5))
    let grid = keyboardControl(app, "candidate-scroll")
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    func visibleCandidates() -> Set<String> {
      let bounds = grid.frame.insetBy(dx: 2, dy: 2)
      return Set(grid.descendants(matching: .any).allElementsBoundByIndex.compactMap {
        let label = $0.label
        return !label.isEmpty && bounds.contains($0.frame) ? label : nil
      })
    }
    for position in 0..<8 {
      let before = visibleCandidates()
      XCTAssertFalse(before.isEmpty, "the installed keyboard must expose visible candidates")
      let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
      start.press(forDuration: 0.05,
                  thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
      XCTAssertNotEqual(visibleCandidates(), before,
                        "the installed keyboard stopped scrolling on drag \(position)")
      let capture = XCTAttachment(screenshot: app.screenshot())
      capture.name = "Expanded ni candidates after drag \(position)"
      capture.lifetime = .keepAlways
      add(capture)
    }
  }

  func testCandidateBarAndExpandRespondRepeatedlyInInstalledKeyboard() throws {
    enableThirdPartyKeyboard()
    let (app, field) = launchAppWithArkeyKeyboard()
    let initial = (field.value as? String) ?? ""
    for iteration in 1...3 {
      for letter in ["n", "i", "h", "a", "o"] {
        app.keys[letter].firstMatch.tap()
      }
      let expand = keyboardControl(app, "展开候选面板")
      XCTAssertTrue(expand.waitForExistence(timeout: 5))
      // Use physical coordinates so accessibility activation cannot bypass hit testing.
      expand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      let collapse = keyboardControl(app, "收起候选面板")
      XCTAssertTrue(collapse.waitForExistence(timeout: 5))
      collapse.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      XCTAssertTrue(expand.waitForExistence(timeout: 5))
      let candidate = app.staticTexts["你好"].firstMatch
      XCTAssertTrue(candidate.waitForExistence(timeout: 5))
      candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      XCTAssertFalse(keyboardControl(app, "展开候选面板").exists)
      XCTAssertEqual((field.value as? String) ?? "", initial + String(repeating: "你好", count: iteration))
    }
  }
}
