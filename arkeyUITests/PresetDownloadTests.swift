import XCTest

final class PresetDownloadTests: XCTestCase {
  func testURLImportOpensAnInputAlertAndCancelKeepsTheLibraryOpen() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    app.openSettingsPage("配置库")
    app.buttons["profile-url-import-button"].tap()
    let alert = app.alerts["从链接下载 ZIP"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    let field = alert.textFields["zip-download-url"]
    XCTAssertTrue(field.exists)
    XCTAssertFalse(alert.buttons["下载"].isEnabled)
    field.tap()
    field.typeText("https://example.com/profile.zip")
    XCTAssertTrue(alert.buttons["下载"].isEnabled)
    alert.buttons["取消"].tap()
    XCTAssertFalse(alert.exists)
    XCTAssertTrue(app.navigationBars["配置库"].exists)
    XCTAssertFalse(app.staticTexts["下载状态"].exists)
  }

  func testProfileLibraryOwnsDownloadNavigation() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 30))
    app.buttons["settings-open"].tap()
    let settings = app.descendants(matching: .any)["settings-list"].firstMatch
    XCTAssertFalse(settings.buttons["下载配置"].exists)
    let library = settings.buttons["配置库"]
    for _ in 0..<5 {
      if library.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(library.isHittable)
    library.tap()
    XCTAssertTrue(app.navigationBars["配置库"].waitForExistence(timeout: 10))
    app.buttons["profile-downloads-link"].tap()
    XCTAssertTrue(app.navigationBars["下载配置"].waitForExistence(timeout: 10))
    let catalog = app.descendants(matching: .any)["preset-downloads"].firstMatch
    XCTAssertFalse(catalog.buttons["配置库"].exists)
    app.navigationBars["下载配置"].buttons.firstMatch.tap()
    XCTAssertTrue(app.navigationBars["配置库"].waitForExistence(timeout: 10))
    app.navigationBars["配置库"].buttons.firstMatch.tap()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
  }

  func testDownloadTapStaysInTheCatalogAndStartsAcquisition() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    app.openSettingsPage("配置库")
    let downloads = app.buttons["profile-downloads-link"]
    XCTAssertTrue(downloads.waitForExistence(timeout: 10))
    downloads.tap()
    let button = app.buttons["download-rime-ice-full"]
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    let originalFrame = button.frame
    button.tap()
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    XCTAssertEqual(button.label, "取消下载")
    XCTAssertEqual(button.frame, originalFrame, "download state must not move or resize the button")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Preset download button progress"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    XCTAssertFalse(app.staticTexts["下载状态"].exists, "download must remain inside the trailing button")
    XCTAssertTrue(app.navigationBars["下载配置"].exists, "download opened an external license page")
    if button.label == "取消下载" && button.isEnabled { button.tap() }
    let ready = NSPredicate(format: "label == %@", "下载")
    expectation(for: ready, evaluatedWith: button)
    waitForExpectations(timeout: 5)
    app.terminate()
  }

  func testFourPresetsDescribeTheirDifferencesWithoutStartingADownload() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    app.openSettingsPage("配置库")
    let downloads = app.buttons["profile-downloads-link"]
    for _ in 0..<5 {
      if downloads.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(downloads.isHittable)
    downloads.tap()
    XCTAssertTrue(app.navigationBars["下载配置"].waitForExistence(timeout: 10))
    for (id, title) in [
      ("rime-ice-full", "雾凇拼音 · 正式版 · 完整"),
      ("rime-ice-lite", "雾凇拼音 · 正式版 · 精简"),
      ("rime-ice-nightly-full", "雾凇拼音 · 开发版 · 完整"),
      ("rime-ice-nightly-slim", "雾凇拼音 · 开发版 · 精简")
    ] {
      let button = app.buttons["download-" + id]
      for _ in 0..<5 {
        if button.isHittable { break }
        app.swipeUp()
      }
      XCTAssertTrue(button.isHittable, id)
      let license = app.buttons["license-" + id]
      XCTAssertTrue(license.exists)
      XCTAssertFalse(button.frame.intersects(license.frame), "download and license hit areas overlap")
      XCTAssertGreaterThan(button.frame.minX, license.frame.maxX, "download belongs at the trailing edge")
      XCTAssertTrue(app.staticTexts[title].exists, title)
    }
    XCTAssertFalse(app.staticTexts["下载状态"].exists, "opening the catalog must not start acquisition")
    let footer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "下载量与完整版相同")).firstMatch
    for _ in 0..<3 {
      if footer.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(footer.exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Preset downloads in Chinese"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
