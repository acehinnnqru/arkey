import XCTest

/// The app's screens, driven for real.
///
/// XCUITest launches the app, taps it and reads what is on the screen — the one thing nothing else in this
/// repository can do: the SwiftUI screens render nothing in the unit-test host (round 153), so this target is
/// where the screens other than the home one are exercised at all.
final class AppScreensTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launched() -> XCUIApplication {
    let app = XCUIApplication()
    app.launch()
    return app
  }

  /// The home screen, which is also the app's own diagnostic: it shows what the engine resolved and what the
  /// typing check answered.
  func testTheHomeScreenShowsTheEngineAndItsStatus() {
    let app = launched()
    XCTAssertTrue(app.staticTexts["在下面的输入框里切换到 Arkey 键盘试试。"].waitForExistence(timeout: 30),
                  "the home screen never appeared")
    XCTAssertTrue(app.navigationBars["Arkey"].exists, "the home screen has no title")
    let engine = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'librime'")).firstMatch
    XCTAssertTrue(engine.waitForExistence(timeout: 10), "the engine's status line is not on the screen")
  }

  /// Every screen the menu offers opens, draws, and can be left again. A screen that traps, that has no
  /// navigation bar, or that cannot be dismissed is exactly what "never run" hides.
  func testEveryScreenInTheMenuOpens() {
    let app = launched()
    XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 30), "the home screen never appeared")

    let screens = ["配置库", "下载配置", "方案与输入", "用户词库", "键盘", "标点", "按键",
                   "自定义短语", "部署", "许可证", "诊断"]
    for name in screens {
      let menu = app.buttons["更多"].firstMatch
      XCTAssertTrue(menu.waitForExistence(timeout: 10), "the more menu is not on the home screen")
      menu.tap()

      let entry = app.buttons[name].firstMatch
      XCTAssertTrue(entry.waitForExistence(timeout: 10), name + " is not in the menu")
      entry.tap()

      let bar = app.navigationBars.firstMatch
      XCTAssertTrue(bar.waitForExistence(timeout: 10), name + " opened no screen")
      // The bar exists while the push is still animating, and a screenshot taken then shows a half-slid
      // screen — which reads as a clipped keyboard (round 154). A beat is enough.
      Thread.sleep(forTimeInterval: 0.6)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = name
      shot.lifetime = .keepAlways
      add(shot)

      bar.buttons.element(boundBy: 0).tap()
      XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 10),
                    "did not come back from " + name)
    }
  }

  /// The toolbar's 键盘 opens the preview — the keyboard drawn from the engine's own layout, which is the
  /// closest this target gets to the extension itself.
  func testTheKeyboardPreviewOpens() {
    let app = launched()
    XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 30), "the home screen never appeared")
    app.buttons["键盘"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10),
                  "the keyboard preview did not open")
    Thread.sleep(forTimeInterval: 0.6)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "keyboard-preview"
    shot.lifetime = .keepAlways
    add(shot)

  }

  /// S1 §9 in the running app: the degraded state names the repair and the button goes where it says. On a
  /// container with nothing deployed the home screen offers 导入或选择配置, and that button opens the profile
  /// library — the screen whose job is choosing one.
  func testTheRecoveryBannerOpensTheProfileLibrary() {
    let app = launched()
    XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 30), "the home screen never appeared")
    let repair = app.buttons["导入或选择配置"].firstMatch
    XCTAssertTrue(repair.waitForExistence(timeout: 10),
                  "the home screen offers no repair: "
                    + app.buttons.allElementsBoundByIndex.prefix(12).map { $0.label }.joined(separator: " | "))
    repair.tap()
    XCTAssertTrue(app.navigationBars["配置库"].waitForExistence(timeout: 10),
                  "the repair did not open the profile library: "
                    + app.navigationBars.allElementsBoundByIndex.map { $0.identifier }.joined(separator: " | "))
  }
}
