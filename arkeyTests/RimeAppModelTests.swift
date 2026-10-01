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

  override func tearDownWithError() throws {
    let model = RimeAppModel()
    if let imported {
      try? RimeDeploymentCoordinator(workspace: model.workspace, engine: model.engine)
        .delete(profileID: imported)
      try? FileManager.default.removeItem(at: model.workspace.activeRecord)
    }
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    imported = nil
    scratch = nil
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
}
