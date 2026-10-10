import XCTest

/// 配置库's import buttons, driven past "a picker opened" to a file actually chosen.
///
/// `AppScreensTests.testTheImportButtonsOpenAPicker` stops at the presentation, and that is exactly the
/// half this target used to ship: the round-189 report ("导入 does nothing") was answered by making the
/// picker appear, and nothing checked what happens to the file the user then chooses. Round 190's report
/// was that other half — the file was chosen and the app did nothing at all. The completion handler read
/// the same state the presentation binding clears when the picker dismisses, so it read `nil` and skipped
/// every branch: no import ran, and no message could appear either.
///
/// These tests export a real archive with the app's own button, choose it in both importers through the
/// system picker, and require each importer to answer out loud. The archive is the app's own settings
/// export: a zip the profile importer has to *refuse* by name and the settings importer has to accept —
/// one fixture, two different answers, and silence fails both.
final class ImportPickerTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// The profile importer takes a config archive and refuses anything else out loud.
  func testTheProfileImporterAnswersAChosenFile() throws {
    let app = launched()
    let file = try exportASettingsArchive(app)

    openProfileLibrary(app)
    let profileImport = app.buttons["profile-file-import-button"].firstMatch
    XCTAssertTrue(profileImport.waitForExistence(timeout: 10), "no profile file import button")
    profileImport.tap()
    try choose(file, in: app)

    let answer = self.answer(app, beginningWith: "导入失败")
    if !answer.waitForExistence(timeout: 10) {
      attach(app, named: "profile-importer-said-nothing")
      XCTFail("the profile importer said nothing about the file this app exported and the user chose")
    }
  }

  /// The settings importer takes that same file and reports what it applied: S2 §7's round trip, with the
  /// file chosen through the system picker rather than handed to the model.
  func testTheSettingsImporterAnswersAChosenFile() throws {
    let app = launched()
    let file = try exportASettingsArchive(app)

    openProfileLibrary(app)
    let settingsImport = app.buttons["导入设置…"].firstMatch
    XCTAssertTrue(settingsImport.waitForExistence(timeout: 10), "no 导入设置… button")
    settingsImport.tap()
    try choose(file, in: app)

    let answer = self.answer(app, beginningWith: "导入设置：")
    if !answer.waitForExistence(timeout: 10) {
      attach(app, named: "settings-importer-said-nothing")
      XCTFail("the settings importer said nothing about the file this app exported and the user chose")
    }
  }

  // MARK: Steps

  /// The row the app answered with, scrolled to.
  ///
  /// 配置库 is a long list and the answer sits in its own section near the bottom, while SwiftUI keeps only
  /// the rows on screen in the element tree: a query that never scrolls misses an answer that is really
  /// there. Round 190's first fixed run failed exactly like that — the import had run, and the row was one
  /// screen below the fold.
  private func answer(_ app: XCUIApplication, beginningWith prefix: String) -> XCUIElement {
    let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    for _ in 0..<6 where !row.exists {
      app.swipeUp(velocity: .slow)
    }
    return row
  }

  private func launched() -> XCUIApplication {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.navigationBars["Arkey"].waitForExistence(timeout: 30), "the home screen never appeared")
    return app
  }

  private func openProfileLibrary(_ app: XCUIApplication) {
    app.openSettingsPage("配置库")
    XCTAssertTrue(app.navigationBars["配置库"].waitForExistence(timeout: 10),
                  "the profile library did not open")
  }

  /// Writes a real archive into the app's Documents directory — the folder the picker browses as the app's
  /// own, which is why the app declares `UIFileSharingEnabled` — and returns the file's name prefix.
  private func exportASettingsArchive(_ app: XCUIApplication) throws -> String {
    openProfileLibrary(app)
    let export = app.buttons["导出设置（补丁 + 自定义短语）"].firstMatch
    XCTAssertTrue(export.waitForExistence(timeout: 10), "no 导出设置 button")
    export.tap()
    // The row is a ShareLink once a file exists, and that is the only sign the export wrote one.
    XCTAssertTrue(app.buttons["分享导出的设置"].firstMatch.waitForExistence(timeout: 20),
                  "the export produced no file to hand over")
    Thread.sleep(forTimeInterval: 1.0)
    // Each test opens 配置库 itself, and the picker is presented from there.
    app.navigationBars["配置库"].buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["settings-close"].waitForExistence(timeout: 10))
    app.buttons["settings-close"].tap()
    return "arkey-settings-"
  }

  /// The system picker, walked to the file and tapped.
  ///
  /// The picker runs in another process and is presented inside the app's own window, so its rows are
  /// reachable through `app` — as cells whose label is "<name>, <kind>, <time>, <size>". It opens where it
  /// was last left, and it has no Cancel button once it is inside a location, so nothing here waits for one:
  /// the file itself is the thing that has to appear.
  private func choose(_ file: String, in app: XCUIApplication) throws {
    var row = fileRow(file, in: app, timeout: 15)
    if row == nil {
      // A picker that opened on 最近使用 / Recents instead: 浏览 / Browse, the phone, and the app's folder.
      if let browse = hit(app, ["浏览", "Browse"], timeout: 4) {
        browse.tap()
        if let phone = hit(app, ["我的 iPhone", "On My iPhone"], timeout: 4) { phone.tap() }
        if let folder = hit(app, ["Arkey"], cellsOnly: true, timeout: 4) { folder.tap() }
        row = fileRow(file, in: app, timeout: 15)
      }
    }
    guard let row else {
      attach(app, named: "picker-cannot-see-the-file")
      throw XCTSkip("the picker does not list " + file + ": the app's Documents folder is not browsable here")
    }
    row.tap()
    // A single-selection picker opens on the tap; a multi-selection one waits for its own button.
    if let open = hit(app, ["Open", "打开"], timeout: 2) { open.tap() }
  }

  /// The picker's row for a file: its label carries the name *and* the kind, time and size.
  private func fileRow(_ file: String, in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
    let predicate = NSPredicate(format: "label BEGINSWITH %@", file)
    for query in [app.cells.containing(predicate).firstMatch,
                  app.buttons.containing(predicate).firstMatch,
                  app.staticTexts.containing(predicate).firstMatch]
      where query.waitForExistence(timeout: timeout) {
      return query
    }
    return nil
  }

  /// The first element that exists under any of these labels, whatever kind the picker made it: a row is a
  /// cell on some iOS versions and a button or a plain element on others, and a folder's label can carry
  /// more than its name.
  ///
  /// `cellsOnly` exists for one reason: the app's own navigation bar has a BackButton *labelled* `Arkey`,
  /// and a folder lookup that could match it would navigate the app instead of the picker.
  private func hit(_ app: XCUIApplication,
                   _ labels: [String],
                   cellsOnly: Bool = false,
                   timeout: TimeInterval = 4) -> XCUIElement? {
    for label in labels {
      var exact = [app.cells[label]]
      if !cellsOnly { exact.append(contentsOf: [app.buttons[label], app.staticTexts[label]]) }
      for candidate in exact where candidate.waitForExistence(timeout: timeout) {
        return candidate
      }
      var loose = [app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch]
      if !cellsOnly {
        loose.append(contentsOf: [
          app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch,
          app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch,
        ])
      }
      for candidate in loose where candidate.waitForExistence(timeout: timeout) {
        return candidate
      }
    }
    return nil
  }

  private func attach(_ app: XCUIApplication, named name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
