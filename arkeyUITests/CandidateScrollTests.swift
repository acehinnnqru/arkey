import XCTest

final class CandidateScrollTests: XCTestCase {
  func testFirstExpansionScrollsAndCollapsesWhileCandidatesLoad() throws {
    let app = XCUIApplication()
    app.launchArguments += ["--candidate-scroll-ui-test", "--candidate-reflow-ui-test"]
    app.launch()
    let expand = app.buttons["展开候选面板"]
    XCTAssertTrue(expand.waitForExistence(timeout: 10))
    expand.tap()
    let grid = app.collectionViews["candidate-scroll"]
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
    XCTAssertGreaterThan(try XCTUnwrap(Int(app.staticTexts["candidate-offset"].label)), 10)
    XCTAssertEqual(app.staticTexts["candidate-selection"].label, "none")
    app.buttons["收起候选面板"].tap()
    XCTAssertTrue(expand.waitForExistence(timeout: 5))
    XCTAssertTrue(expand.isHittable)
    XCTAssertFalse(grid.isHittable)
    expand.tap()
    XCTAssertTrue(grid.buttons["Candidate 0"].isHittable)
  }

  func testExpansionReflowsFromFirstCandidateAndReservesTheAccessoryRail() throws {
    let app = XCUIApplication()
    app.launchArguments += ["--candidate-scroll-ui-test", "--candidate-reflow-ui-test"]
    app.launch()
    let bar = app.scrollViews["candidate-bar-scroll"]
    XCTAssertTrue(bar.waitForExistence(timeout: 10))
    bar.swipeLeft()
    let before = try XCTUnwrap(Int(app.staticTexts["candidate-bar-offset"].label))
    XCTAssertGreaterThan(before, 0)
    app.buttons["展开候选面板"].tap()
    let grid = app.collectionViews["candidate-scroll"]
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    let first = grid.buttons["Candidate 0"]
    XCTAssertTrue(first.isHittable)
    let collapse = app.buttons["收起候选面板"]
    XCTAssertLessThanOrEqual(grid.frame.maxX, collapse.frame.minX + 1)
    XCTAssertLessThanOrEqual(abs(grid.frame.minY - collapse.frame.minY), 1)
    grid.swipeUp()
    XCTAssertLessThanOrEqual(grid.frame.maxX, collapse.frame.minX + 1)
    collapse.tap()
    XCTAssertTrue(bar.isHittable)
    XCTAssertEqual(try XCTUnwrap(Int(app.staticTexts["candidate-bar-offset"].label)), before)
    app.buttons["展开候选面板"].tap()
    XCTAssertTrue(first.isHittable)
    first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertEqual(app.staticTexts["candidate-selection"].label, "0")
  }

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
      bounds.contains($0.frame) && $0.isHittable
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

    func capture(_ position: String) {
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = "Long candidate list at \(position)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    capture("top")

    for _ in 0..<5 {
      let before = try offset()
      let bounds = scroll.frame.insetBy(dx: 8, dy: 20)
      let candidate = try XCTUnwrap(scroll.buttons.allElementsBoundByIndex.first {
        bounds.contains($0.frame) && $0.isHittable && $0.frame.midY > scroll.frame.midY
      }, "no candidate available to start a drag")
      let start = candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
      XCTAssertGreaterThan(try offset(), before + 10, "an upward drag did not move the candidates")
      XCTAssertEqual(app.staticTexts["candidate-selection"].label, "none",
                     "dragging a candidate must not select it")
    }
    capture("scrolled")
    for _ in 0..<5 {
      let before = try offset()
      let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
      XCTAssertLessThan(try offset(), before - 10, "a downward drag did not move the candidates")
      XCTAssertEqual(app.staticTexts["candidate-selection"].label, "none")
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
      $0.label.hasPrefix("候选词") && bounds.contains($0.frame) && $0.isHittable
    }, "no fully visible candidate after the swipe")
    let expected = String(candidate.label.dropFirst("候选词".count))
    candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertEqual(selection.label, expected)
  }
}
