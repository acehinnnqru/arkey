import XCTest

final class LocalizationUITests: XCTestCase {
  func testChineseInputOnlySettingPersistsAfterRelaunch() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 30))
    app.buttons["settings-open"].tap()
    openLanguagePicker(app)
    app.buttons["简体中文"].tap()
    let settingsList = app.collectionViews["settings-list"]
    let keyboardSettings = app.buttons["keyboard-settings-open"]
    for _ in 0..<5 {
      if keyboardSettings.isHittable { break }
      settingsList.swipeDown()
    }
    XCTAssertTrue(keyboardSettings.isHittable)
    keyboardSettings.tap()
    let toggle = app.switches["chinese-input-only"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    XCTAssertTrue(toggle.label.contains("仅使用中文输入"))
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    let original = toggle.value as? String
    let changed = original == "1" ? "0" : "1"
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", changed), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 30))
    app.buttons["settings-open"].tap()
    XCTAssertTrue(keyboardSettings.waitForExistence(timeout: 10))
    keyboardSettings.tap()
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    XCTAssertEqual(toggle.value as? String, changed)
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", original ?? "0"), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
  }

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
    assertKeyboardSection("Appearance", in: app)

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
    assertKeyboardSection("外观", in: app)
  }

  private func assertKeyboardSection(_ title: String, in app: XCUIApplication) {
    let section = app.staticTexts[title]
    let list = app.collectionViews.firstMatch
    for _ in 0..<6 {
      if section.exists { break }
      list.swipeUp()
    }
    XCTAssertTrue(section.waitForExistence(timeout: 5))
  }

  private func openLanguagePicker(_ app: XCUIApplication) {
    let list = app.collectionViews["settings-list"]
    let picker = list.buttons["interface-language"]
    for _ in 0..<4 {
      if picker.isHittable { break }
      list.swipeUp()
    }
    XCTAssertTrue(picker.isHittable)
    picker.tap()
  }

  private func tapSettingsRow(_ title: String, in app: XCUIApplication) {
    let list = app.collectionViews["settings-list"]
    let row = list.buttons[title]
    for _ in 0..<4 {
      if row.isHittable { break }
      list.swipeDown()
    }
    XCTAssertTrue(row.isHittable)
    row.tap()
  }
}
