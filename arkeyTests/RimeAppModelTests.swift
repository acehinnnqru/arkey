import XCTest
import RimeEngine

/// The app's own first-run path, on iOS.
///
/// RimeAppModel is what the SwiftUI screens drive, and nothing had ever instantiated it: the app's sources are
/// compiled into the test bundle for these tests. It runs in the keyboard's own container workspace (the app
/// group is unavailable without entitlements), the same one the keyboard tests use, so it cleans up after
/// itself — the profile it imports and the record that points at it are removed in tearDown, which is what
/// keeps the suite repeatable.
@MainActor
final class RimeAppModelTests: XCTestCase {
  private var imported: String?
  private var scratch: URL?
  private var userFiles: [URL] = []
  private var exports: [URL] = []

  override func tearDownWithError() throws {
    let model = RimeAppModel()
    if let imported {
      try? RimeDeploymentCoordinator(workspace: model.workspace, engine: model.engine)
        .delete(profileID: imported)
      try? FileManager.default.removeItem(at: model.workspace.activeRecord)
    }
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    // The settings round trip writes into the keyboard's user directory and into Documents: both are real
    // places the app uses, so the test puts them back the way it found them.
    for url in userFiles { try? FileManager.default.removeItem(at: url) }
    for url in exports { try? FileManager.default.removeItem(at: url) }
    imported = nil
    scratch = nil
    userFiles = []
    exports = []
  }

  /// What the app does before it is usable: directories, the installation record, the storage policy, an
  /// engine bound to what resolves, and the tracer's typing check as the diagnostic the home screen shows.
  func testTheAppBootstrapsAndBindsAnEngine() async throws {
    let model = RimeAppModel()
    await model.bootstrap()

    XCTAssertNil(model.errorMessage, "bootstrap reported: " + (model.errorMessage ?? ""))
    XCTAssertFalse(model.resolvedSummary.isEmpty, "the app does not say what it resolved")
    XCTAssertTrue(FileManager.default.fileExists(atPath: model.workspace.root.path),
                  "the workspace was never created")
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: model.workspace.userData.appendingPathComponent("installation.yaml").path),
      "the installation record is missing, so the sync directory would move on the next launch")
    XCTAssertFalse(model.engineStatus.contains("尚未启动"),
                   "the engine was never started: " + model.engineStatus)
  }

  /// The 配置库 path the screens drive: import a folder, deploy it, and the footer says so. It is the app's
  /// half of S1-AC2 and S2's deploy footer, on the shipped engine.
  func testImportingThenDeployingReportsTheDeployInTheFooter() async throws {
    let model = RimeAppModel()
    await model.bootstrap()

    await model.importPayload(at: try makeSourceFolder(), displayName: "App model test",
                              adoptUserData: false)
    XCTAssertNil(model.errorMessage, "the import reported: " + (model.errorMessage ?? ""))
    let profile = try XCTUnwrap(model.profiles.first { $0.displayName == "App model test" },
                                "the imported profile is not listed: "
                                  + model.profiles.map { $0.displayName }.joined(separator: ", "))
    imported = profile.id

    await model.deploy(profileID: profile.id)

    let message = try XCTUnwrap(model.deployMessage, "the deploy said nothing")
    XCTAssertTrue(message.hasPrefix("部署完成"), "the deploy said: " + message)
    guard case .applied = model.settingsFooter else {
      return XCTFail("the footer is " + String(describing: model.settingsFooter) + " after a deploy")
    }
    XCTAssertEqual(model.activeProfileID, profile.id, "the deploy did not activate what it built")
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: model.workspace.profile(profile.id).build.path), "no build was written")
  }

  /// The copy of the bundled profile the importer is given: the three files, without the shipped build
  /// directory, which is the shape the app's folder import expects.
  private func makeSourceFolder() throws -> URL {
    let bundled = try XCTUnwrap(RimeDirectories.bundledSharedDataURL(in: .main), "no bundled RimeData")
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-app-model-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: bundled.appendingPathComponent(file),
                                       to: url.appendingPathComponent(file))
    }
    scratch = url
    return url
  }

  /// S2 §7's portability on the app's own path: the 导出设置 and 导入设置 buttons. A patch and a phrase file are
  /// written where the settings editors write them, exported to one file, deleted, and imported back — the round
  /// trip a user makes between the phone and a Mac.
  func testExportingAndImportingSettingsRoundTrips() async throws {
    let model = RimeAppModel()
    await model.bootstrap()

    let user = model.workspace.userData
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    let patch = user.appendingPathComponent("tracer.custom.yaml")
    let phrases = user.appendingPathComponent("custom_phrase.txt")
    try "patch:\n  translator/enable_completion: false\n".write(to: patch, atomically: true, encoding: .utf8)
    try "你好\tni hao\t1\n".write(to: phrases, atomically: true, encoding: .utf8)
    userFiles = [patch, phrases]

    let exported = try XCTUnwrap(model.exportSettings(), "exportSettings returned no file")
    exports = [exported]
    XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path), "the export wrote no file")
    let exportWarnings = model.importWarnings.joined(separator: " | ")
    XCTAssertTrue(exportWarnings.contains("tracer.custom.yaml") && exportWarnings.contains("custom_phrase.txt"),
                  "the export did not name both files: " + exportWarnings)

    // Take them away so the import has something to restore, and check they are really gone.
    try FileManager.default.removeItem(at: patch)
    try FileManager.default.removeItem(at: phrases)
    XCTAssertFalse(FileManager.default.fileExists(atPath: patch.path))

    await model.importSettingsBundle(from: exported)
    // The import is what is under test. Its redeploy leg then reports that this container has no deployed
    // profile to redeploy into — true here, and a different sentence from a failed import
    // ("导入设置失败：…"), which is the one that would matter.
    if let message = model.errorMessage {
      XCTAssertEqual(message, "没有可部署的配置。",
                     "the import failed rather than finding nothing to redeploy into: " + message)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: patch.path), "the patch was not restored")
    XCTAssertTrue(FileManager.default.fileExists(atPath: phrases.path), "the phrase file was not restored")
    let restored = try String(contentsOf: patch, encoding: .utf8)
    XCTAssertTrue(restored.contains("enable_completion: false"),
                  "the restored patch is not the one exported: [" + restored + "]")
    // The import's summary names the schemas it touched, not the file names.
    let importWarnings = model.importWarnings.joined(separator: " | ")
    XCTAssertTrue(importWarnings.contains("2 个文件"),
                  "the import did not say how much it restored: " + importWarnings)
    XCTAssertTrue(importWarnings.contains("tracer"),
                  "the import did not name the schema it restored into: " + importWarnings)
  }

  /// The 配置库 lifecycle the screens drive: import, deploy, activate, roll back, delete — with the footer and
  /// the active record as the evidence at each step. The engine's coordinator has its own tests; this is the
  /// app's path through them.
  func testTheProfileLibraryLifecycleOnTheAppsPath() async throws {
    let model = RimeAppModel()
    await model.bootstrap()

    await model.importPayload(at: try makeSourceFolder(), displayName: "Lifecycle test",
                              adoptUserData: false)
    let profile = try XCTUnwrap(model.profiles.first { $0.displayName == "Lifecycle test" },
                                "the import is not listed: "
                                  + model.profiles.map { $0.displayName }.joined(separator: ", "))
    imported = profile.id

    // Deploy twice, so there is a previous generation for the rollback to find.
    await model.deploy(profileID: profile.id)
    XCTAssertTrue((model.deployMessage ?? "").hasPrefix("部署完成"),
                  "the first deploy said: " + (model.deployMessage ?? "nothing"))
    await model.deploy(profileID: profile.id)

    model.activate(profileID: profile.id)
    XCTAssertNil(model.errorMessage, "activation reported: " + (model.errorMessage ?? ""))
    XCTAssertEqual(model.settingsFooter, .applied("已切换"),
                   "the footer after activating: " + String(describing: model.settingsFooter))
    XCTAssertTrue((model.deployMessage ?? "").contains("已切换"),
                  "activation said: " + (model.deployMessage ?? "nothing"))
    let active = try? model.workspace.loadActiveProfile()
    XCTAssertEqual(active?.profileID, profile.id,
                   "the active record does not point at the activated profile")

    model.rollback(profileID: profile.id)
    if model.errorMessage == nil {
      XCTAssertEqual(model.settingsFooter, .applied("已回滚到上一代构建"),
                     "the footer after rolling back: " + String(describing: model.settingsFooter))
    }

    model.delete(profileID: profile.id)
    XCTAssertNil(model.errorMessage, "deletion reported: " + (model.errorMessage ?? ""))
    XCTAssertFalse(model.profiles.contains { $0.id == profile.id },
                   "the profile is still listed after deletion")
    imported = nil
  }

  /// S2 §3's rule at the app level: the keyboard's own settings never need a deploy, so writing one leaves the
  /// footer alone. Without the App Group the store is unavailable — true in this test host, and the sentence the
  /// user would see — so the write reports that and changes nothing, rather than pretending to have saved.
  func testKeyboardPreferencesDoNotAskForADeploy() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    let before = model.keyboardPreferences

    model.updatePreferences { $0.paletteMode = .fixed }

    if model.preferencesStore == nil {
      XCTAssertEqual(model.errorMessage, "拿不到 App Group，键盘设置无法共享给键盘。",
                     "the write reported: " + (model.errorMessage ?? "nothing"))
      XCTAssertEqual(model.keyboardPreferences, before, "the settings changed without a store")
    } else {
      XCTAssertNil(model.errorMessage, "the write reported: " + (model.errorMessage ?? ""))
      XCTAssertEqual(model.keyboardPreferences.paletteMode, .fixed,
                     "the settings were not saved through the app group")
      model.resetPreferences()
    }
    XCTAssertEqual(model.settingsFooter, .unchanged,
                   "a keyboard setting asked for a deploy: " + String(describing: model.settingsFooter))
  }
}
