import XCTest
@testable import RimeEngine

/// S1-AC6's second half: the app installs `RimeData.local/` when a build carries one, and does it once.
/// The first half — that a Release bundle never carries it — is S6-AC3's check.
final class S1LocalDataTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL { repositoryRoot.appendingPathComponent("RimeData", isDirectory: true) }

  private func makeWorkspace() throws -> RimeWorkspace {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s1-local", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try RimeWorkspace(root: root).createDirectories()
  }

  /// A `RimeData.local` directory shaped like a real local config.
  private func makeLocalData() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RimeData.local", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent(RimeLocalDataInstaller.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file),
                                       to: directory.appendingPathComponent(file))
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    return directory
  }

  func testALocalDirectoryIsInstalledAndActivatedOnce() throws {
    let workspace = try makeWorkspace()
    let engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: workspace.staging.path,
      prebuiltDataDir: workspace.staging.path,
      userDataDir: workspace.userData.path,
      stagingDir: workspace.staging.path,
      logDir: workspace.log.path)))
    defer { engine.shutdown() }
    _ = try engine.start()
    let localData = try makeLocalData()

    let installed = try RimeLocalDataInstaller.installIfPresent(at: localData, workspace: workspace,
                                                                engine: engine)
    let id = try XCTUnwrap(installed, "a directory that is there is installed")
    XCTAssertEqual(try workspace.loadActiveProfile()?.profileID, id, "and activated")

    XCTAssertNil(try RimeLocalDataInstaller.installIfPresent(at: localData, workspace: workspace,
                                                             engine: engine),
                 "a second launch installs nothing: the id is content-addressed")
    XCTAssertEqual(try workspace.loadActiveProfile()?.profileID, id, "and the active profile is unchanged")
  }

  func testADebugBuildWithoutALocalDirectoryInstallsNothing() throws {
    let workspace = try makeWorkspace()
    let engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: workspace.staging.path,
      prebuiltDataDir: workspace.staging.path,
      userDataDir: workspace.userData.path,
      stagingDir: workspace.staging.path,
      logDir: workspace.log.path)))
    defer { engine.shutdown() }
    _ = try engine.start()

    let missing = workspace.root.appendingPathComponent(RimeLocalDataInstaller.directoryName)
    XCTAssertNil(try RimeLocalDataInstaller.installIfPresent(at: missing, workspace: workspace,
                                                             engine: engine))
    XCTAssertNil(try workspace.loadActiveProfile(), "and nothing was activated")
  }
}
