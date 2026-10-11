import XCTest

final class LocalizationUITests: XCTestCase {
  func testPersonalSourceExportIsAvailableAndLocalizedInBothLanguages() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 30))
    app.buttons["settings-open"].tap()
    openLanguagePicker(app)
    app.buttons["English"].tap()
    tapSettingsRow("User dictionaries", in: app)
    XCTAssertTrue(app.navigationBars["User dictionaries"].waitForExistence(timeout: 10))
    let export = app.buttons["export-personal-dictionary"]
    for _ in 0..<5 {
      if export.isHittable { break }
      app.swipeUp()
    }
    XCTAssertEqual(export.label, "Export personal sources…")
    XCTAssertTrue(export.isHittable)
    export.tap()
    let share = app.buttons["share-personal-dictionary"]
    XCTAssertTrue(share.waitForExistence(timeout: 20), "source export did not produce a shareable file")
    XCTAssertEqual(share.label, "Share personal sources")

    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 30))
    app.buttons["settings-open"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    openLanguagePicker(app)
    app.buttons["简体中文"].tap()
    tapSettingsRow("用户词库", in: app)
    XCTAssertTrue(app.navigationBars["用户词库"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["export-personal-dictionary"].label, "导出个人源数据…")
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "源数据独立于已安装配置保存")).firstMatch.exists)
  }

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
