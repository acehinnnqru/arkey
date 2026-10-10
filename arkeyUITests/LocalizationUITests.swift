import XCTest

final class LocalizationUITests: XCTestCase {
  func testLanguageChangesInPlaceAndPersistsAfterRelaunch() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 30))
    app.buttons["settings-open"].tap()
    XCTAssertTrue(app.otherElements["settings-list"].waitForExistence(timeout: 10)
                  || app.collectionViews["settings-list"].exists)

    // Native language names make the picker usable even if a previous run selected English.
    openLanguagePicker(app)
    app.buttons["简体中文"].tap()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    openLanguagePicker(app)
    app.buttons["跟随系统"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5),
                  "changing language dismissed or failed to update the settings sheet")
    tapSettingsRow("Keyboard", in: app)
    XCTAssertTrue(app.navigationBars["Keyboard"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Appearance"].exists)

    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 30))
    app.buttons["settings-open"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    openLanguagePicker(app)
    XCTAssertTrue(app.buttons["Follow System"].isSelected)
    app.buttons["English"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    openLanguagePicker(app)
    app.buttons["简体中文"].tap()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    tapSettingsRow("键盘", in: app)
    XCTAssertTrue(app.staticTexts["外观"].waitForExistence(timeout: 5))
  }

  private func openLanguagePicker(_ app: XCUIApplication) {
    let picker = app.buttons["interface-language"]
    for _ in 0..<4 {
      if picker.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(picker.isHittable)
    picker.tap()
  }

  private func tapSettingsRow(_ title: String, in app: XCUIApplication) {
    let row = app.buttons[title]
    for _ in 0..<4 {
      if row.isHittable { break }
      app.swipeDown()
    }
    XCTAssertTrue(row.isHittable)
    row.tap()
  }
}
