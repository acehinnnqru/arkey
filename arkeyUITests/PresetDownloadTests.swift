import XCTest

final class PresetDownloadTests: XCTestCase {
  func testFourPresetsDescribeTheirDifferencesWithoutStartingADownload() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    app.openSettingsPage("下载配置")
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
