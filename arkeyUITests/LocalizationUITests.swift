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
    app.buttons["interface-language"].tap()
    app.buttons["简体中文"].tap()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    app.buttons["interface-language"].tap()
    app.buttons["English"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5),
                  "changing language dismissed or failed to update the settings sheet")
    app.buttons["Keyboard"].tap()
    XCTAssertTrue(app.navigationBars["Keyboard"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Appearance"].exists)

    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 30))
    app.buttons["settings-open"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    app.buttons["interface-language"].tap()
    app.buttons["简体中文"].tap()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    app.buttons["键盘"].tap()
    XCTAssertTrue(app.staticTexts["外观"].waitForExistence(timeout: 5))
  }
}
