import XCTest

final class CandidateScrollTests: XCTestCase {
  func testCollapsedRowDragsOverButtonsAndSelectsAfterScrolling() throws {
    let app = XCUIApplication()
    app.launchArguments.append("--candidate-scroll-ui-test")
    app.launch()
    let scroll = app.scrollViews["candidate-bar-scroll"]
    let offset = app.staticTexts["candidate-bar-offset"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 10))
    func position() throws -> Int { try XCTUnwrap(Int(offset.label)) }
    for _ in 0..<2 {
      let before = try position()
      scroll.swipeLeft()
      XCTAssertGreaterThan(try position(), before + 10)
    }
    let bounds = scroll.frame.insetBy(dx: 4, dy: 0)
    let candidate = try XCTUnwrap(scroll.buttons.allElementsBoundByIndex.first {
      $0.isHittable && bounds.contains($0.frame)
    })
    let index = String(candidate.label.dropFirst("Candidate ".count))
    XCTAssertGreaterThan(try XCTUnwrap(Int(index)), 4,
                         "the strip must reach candidates beyond the initial engine page")
    candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertEqual(app.staticTexts["candidate-selection"].label, "bar-" + index)
    let before = try position()
    scroll.swipeRight()
    XCTAssertLessThan(try position(), before - 10)
    let expand = app.buttons["展开候选面板"]
    XCTAssertTrue(expand.isHittable)
    XCTAssertGreaterThanOrEqual(expand.frame.minX, scroll.frame.maxX - 1)
  }

  func testRepeatedDragsKeepScrollingOverCandidateCells() throws {
    let app = XCUIApplication()
    app.launchArguments.append("--candidate-scroll-ui-test")
    app.launch()

    let scroll = app.collectionViews["candidate-scroll"]
    let offsetLabel = app.staticTexts["candidate-offset"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 10))
    XCTAssertTrue(offsetLabel.waitForExistence(timeout: 10))

    func offset() throws -> Int {
      try XCTUnwrap(Int(offsetLabel.label), "invalid scroll offset: \(offsetLabel.label)")
    }

    for _ in 0..<5 {
      let before = try offset()
      scroll.swipeUp()
      XCTAssertGreaterThan(try offset(), before + 10, "an upward drag did not move the candidates")
    }
    for _ in 0..<5 {
      let before = try offset()
      scroll.swipeDown()
      XCTAssertLessThan(try offset(), before - 10, "a downward drag did not move the candidates")
    }
  }

  func testPhysicalCandidateTapStillSelectsAfterScrolling() throws {
    let app = XCUIApplication()
    app.launchArguments.append("--candidate-scroll-ui-test")
    app.launch()

    let scroll = app.collectionViews["candidate-scroll"]
    let selection = app.staticTexts["candidate-selection"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 10))
    XCTAssertTrue(selection.waitForExistence(timeout: 10))
    let first = scroll.buttons.matching(NSPredicate(format: "label == %@", "候选词0")).firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertEqual(selection.label, "0")
    scroll.swipeUp()
    Thread.sleep(forTimeInterval: 1)
    let bounds = scroll.frame.insetBy(dx: 8, dy: 20)
    let candidate = try XCTUnwrap(scroll.buttons.allElementsBoundByIndex.first {
      $0.label.hasPrefix("候选词") && $0.isHittable && bounds.contains($0.frame)
    }, "no fully visible candidate after the swipe")
    let expected = String(candidate.label.dropFirst("候选词".count))
    candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertEqual(selection.label, expected)
  }
}
