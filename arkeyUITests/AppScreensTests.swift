import XCTest

/// The app's screens, driven for real.
///
/// XCUITest launches the app, taps it and reads what is on the screen — the one thing nothing else in this
/// repository can do: the SwiftUI screens render nothing in the unit-test host (round 153), so this target is
/// where the screens other than the home one are exercised at all.
///
/// "A screen opened" used to mean "some navigation bar exists", which a blank page would satisfy. Each screen
/// now has to show its own title and a line of its own content (round 162).
final class AppScreensTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// The menu entry, the title the screen gives itself, and a line only that screen carries.
  private static let screens: [(menu: String, title: String, content: String)] = [
    ("配置库", "配置库", "当前生效"),
    ("下载配置", "下载配置", "可选配置"),
    ("方案与输入", "方案", "第一个是默认方案"),
    ("用户词库", "用户词库", "用户词典"),
    ("键盘", "键盘", "外观"),
    ("标点", "标点", "符号表"),
    ("按键", "按键", "按键绑定"),
    ("自定义短语", "自定义短语", "短语（0）"),
    ("部署", "部署", "上一次部署"),
    ("许可证", "许可证", "第三方配置与许可证"),
    ("诊断", "诊断", "shared"),
  ]

  private func launched() -> XCUIApplication {
    let app = XCUIApplication()
    app.launch()
    return app
  }

  private func contains(_ app: XCUIApplication, _ text: String) -> XCUIElement {
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  /// The home screen, which is also the app's own diagnostic: it shows what the engine resolved and what the
  /// typing check answered.
  func testTheHomeScreenShowsTheEngineAndItsStatus() {
    let app = launched()
    XCTAssertTrue(app.staticTexts["在下面的输入框里切换到 Arkey 键盘试试。"].waitForExistence(timeout: 30),
                  "the home screen never appeared")
    XCTAssertTrue(app.navigationBars["Arkey"].exists, "the home screen has no title")

    // The engine's line, not just a line with a version in it: the app runs its own typing check at startup,
    // and the answer is on the screen.
    let engine = contains(app, "librime")
    XCTAssertTrue(engine.waitForExistence(timeout: 10), "the engine's status line is not on the screen")
    XCTAssertTrue(engine.label.contains("nihao") && engine.label.contains("你好"),
                  "the status line does not carry the typing check's answer: [" + engine.label + "]")

    // Nothing is deployed in this container, so the resolved profile is the bundled fallback and the repair is
    // offered (S1 §9) — the state the rest of these tests depend on.
    XCTAssertTrue(contains(app, "内置数据").waitForExistence(timeout: 5),
                  "the home screen does not name the resolved profile")
    XCTAssertTrue(app.buttons["导入或选择配置"].exists, "the degraded state offers no repair")
  }

  /// Every screen the menu offers opens, draws its own content, and can be left again. A screen that traps,
  /// that shows nothing, or that cannot be dismissed is exactly what "never run" hides.
  func testEveryScreenInTheMenuOpens() {
    let app = launched()
    XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 30), "the home screen never appeared")

    for screen in Self.screens {
      let menu = app.buttons["更多"].firstMatch
      XCTAssertTrue(menu.waitForExistence(timeout: 10), "the more menu is not on the home screen")
      menu.tap()

      let entry = app.buttons[screen.menu].firstMatch
      XCTAssertTrue(entry.waitForExistence(timeout: 10), screen.menu + " is not in the menu")
      entry.tap()

      let bar = app.navigationBars[screen.title]
      XCTAssertTrue(bar.waitForExistence(timeout: 10),
                    screen.menu + " did not open its own screen: the bar says "
                      + app.navigationBars.firstMatch.identifier)
      XCTAssertTrue(contains(app, screen.content).waitForExistence(timeout: 5),
                    screen.title + " shows none of its own content (" + screen.content + "): "
                      + app.staticTexts.allElementsBoundByIndex.prefix(6).map { $0.label }
                        .joined(separator: " | "))

      // A container path belongs on the diagnostics screen and nowhere else: everywhere else it is a sentence
      // about the user's phone that the user cannot act on (S1 §9, and round 165 had one reach the UI next to a
      // real failure).
      let pathLeak = app.staticTexts.allElementsBoundByIndex
        .first { $0.label.contains("/Users/") || $0.label.contains("/var/mobile") }
      // 诊断 and 部署 are where internals are the subject — the workspace's own paths and librime's log, which
      // is the text a bug report needs. Everywhere else a path is a sentence about the user's phone that the
      // user cannot act on.
      if ["诊断", "部署"].contains(screen.menu) {
        XCTAssertNotNil(pathLeak, screen.menu + " shows no real internals at all")
      } else {
        XCTAssertNil(pathLeak, screen.menu + " shows a filesystem path: [" + (pathLeak?.label ?? "") + "]")
      }

      Thread.sleep(forTimeInterval: 0.6)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = screen.menu
      shot.lifetime = .keepAlways
      add(shot)

      bar.buttons.element(boundBy: 0).tap()
      XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 10),
                    "did not come back from " + screen.menu)
    }
  }

  /// The toolbar's 键盘 opens the preview — the keyboard drawn from the shared view code, with the fixture page
  /// on its bar. That page is what makes this more than "a screen opened": the preview has to have drawn the
  /// keyboard's own views.
  func testTheKeyboardPreviewOpens() {
    let app = launched()
    XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 30), "the home screen never appeared")
    app.buttons["键盘"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["键盘预览"].waitForExistence(timeout: 10),
                  "the keyboard preview did not open: " + app.navigationBars.firstMatch.identifier)

    let candidate = contains(app, "你好")
    XCTAssertTrue(candidate.waitForExistence(timeout: 5),
                  "the preview drew no candidate bar: "
                    + app.staticTexts.allElementsBoundByIndex.prefix(8).map { $0.label }
                      .joined(separator: " | "))
    XCTAssertTrue(candidate.label.contains("ni hao"),
                  "the preview's first cell is not the fixture candidate: [" + candidate.label + "]")

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

  /// The diagnostics screen shows the running engine's own values, not placeholders: the version line is the
  /// one librime reports at startup.
  func testTheDiagnosticsScreenShowsTheEngineVersion() {
    let app = launched()
    XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 30), "the home screen never appeared")
    app.buttons["更多"].firstMatch.tap()
    let entry = app.buttons["诊断"].firstMatch
    XCTAssertTrue(entry.waitForExistence(timeout: 10), "no diagnostics entry")
    entry.tap()
    let version = contains(app, "librime")
    XCTAssertTrue(version.waitForExistence(timeout: 10),
                  "the diagnostics screen shows no engine version: "
                    + app.staticTexts.allElementsBoundByIndex.prefix(14).map { $0.label }
                      .joined(separator: " | "))
    XCTAssertTrue(version.label.contains("1.17"),
                  "the version line does not carry the engine's version: [" + version.label + "]")
  }

  func testDiagnosticsCopyCanBePastedIntoTheEditor() {
    let app = launched()
    XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 30))
    app.buttons["更多"].firstMatch.tap()
    app.buttons["诊断"].firstMatch.tap()
    let copy = app.buttons["diagnostics-copy"]
    XCTAssertTrue(copy.waitForExistence(timeout: 10))
    copy.tap()
    XCTAssertTrue(app.alerts["Diagnostics"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Copied'")).firstMatch.exists)
    app.alerts.buttons["OK"].tap()
    app.navigationBars.buttons.firstMatch.tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.press(forDuration: 1.2)
    let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Paste", "粘贴"])).firstMatch
    XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
    paste.tap()
    XCTAssertTrue(((editor.value as? String) ?? "").contains("Arkey diagnostics"))
  }

  /// The import buttons open a picker — the profile library's toolbar 导入 and its 导入设置… row, and the
  /// dictionary screen's 选择同步文件夹…. Nothing tapped them, so the round-189 report that 导入 did nothing
  /// shipped unnoticed: both screens stacked two fileImporters on one view and neither presented.
  ///
  /// Each button is checked from a fresh launch. The picker belongs to the system and this test cannot reliably
  /// dismiss it — it used to tap the picker's Cancel, which is its *root* chrome, and round 190's app declares
  /// file sharing, so the picker opens inside a location where there is no Cancel at all. Relaunching is the
  /// reset that does not depend on the picker's location.
  func testTheImportButtonsOpenAPicker() {
    assertAPickerOpens(menu: "配置库", button: "导入")
    assertAPickerOpens(menu: "配置库", button: "导入设置…")
    assertAPickerOpens(menu: "用户词库", button: "选择同步文件夹…")
  }

  private func assertAPickerOpens(menu: String, button: String) {
    let app = launched()
    XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 30), "the home screen never appeared")
    app.buttons["更多"].firstMatch.tap()
    let entry = app.buttons[menu].firstMatch
    XCTAssertTrue(entry.waitForExistence(timeout: 10), menu + " is not in the menu")
    entry.tap()
    XCTAssertTrue(app.navigationBars[menu].waitForExistence(timeout: 10), menu + " did not open")

    let target = app.buttons[button].firstMatch
    XCTAssertTrue(target.waitForExistence(timeout: 10), menu + " has no " + button + " button")
    XCTAssertTrue(target.isEnabled, button + " is disabled")
    target.tap()
    XCTAssertTrue(pickerOf(app).waitForExistence(timeout: 15),
                  "tapping " + button + " opened no picker: " + inventory(app))
    app.terminate()
  }

  /// The picker itself, wherever it opens: the browser it presents and the search field it always carries.
  /// The Cancel button this used to look for is the picker's root chrome, not the picker.
  private func pickerOf(_ app: XCUIApplication) -> XCUIElement {
    let browser = app.otherElements["Browse View (Picker)"]
    if browser.exists { return browser }
    let english = app.searchFields["Search"]
    return english.exists ? english : app.searchFields["搜索"].firstMatch
  }

  /// What is on screen, element by element. An indexed walk of the whole tree was what this reported with
  /// before, and it failed the test with "No matches found for Element at index 7" instead — the tree changes
  /// under an enumerating query while the picker animates (round 190).
  private func inventory(_ app: XCUIApplication) -> String {
    let labels = ["Cancel", "取消", "Open", "打开", "Browse", "浏览", "Recents", "最近使用", "Search", "搜索"]
    let present = labels.filter { app.buttons[$0].exists || app.searchFields[$0].exists }
    return present.isEmpty ? "no picker chrome on screen" : present.joined(separator: " | ")
  }
}
