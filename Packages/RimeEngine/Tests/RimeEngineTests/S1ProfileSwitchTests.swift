import XCTest
@testable import RimeEngine

/// S1-AC3's second half: switching between two profiles and back must not lose what the user taught
/// the keyboard. The user directory is deliberately shared across profiles — a dictionary belongs to
/// a dictionary *name*, not to a profile — and this is the test that holds that claim.
final class S1ProfileSwitchTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL { repositoryRoot.appendingPathComponent("RimeData", isDirectory: true) }

  private var scratch: URL!
  private var workspace: RimeWorkspace!
  private var engine: RimeEngine!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s1-switch", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()

    let directories = RimeDirectories(sharedDataDir: tracerData.path,
                                      prebuiltDataDir: tracerData.appendingPathComponent("build").path,
                                      userDataDir: workspace.userData.path,
                                      stagingDir: workspace.staging.path,
                                      logDir: workspace.log.path)
    engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.start()
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    try? FileManager.default.removeItem(at: scratch)
  }

  /// A profile that learns, which the tracer's own schema does not.
  private func importLearningProfile(name: String) throws -> String {
    let source = scratch.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file),
                                       to: source.appendingPathComponent(file))
    }
    let schema = try String(contentsOf: source.appendingPathComponent("tracer.schema.yaml"),
                            encoding: .utf8)
    try schema.replacingOccurrences(of: "enable_user_dict: false", with: "enable_user_dict: true")
      .write(to: source.appendingPathComponent("tracer.schema.yaml"), atomically: true, encoding: .utf8)
    return try RimeImporter(workspace: workspace, engine: engine)
      .import(payload: source,
              options: RimeImportOptions(displayName: name,
                                         origin: RimeProfileSource(kind: .files))).profileID
  }

  private func exportText(_ name: String) throws -> String {
    let url = scratch.appendingPathComponent("export-" + name + ".txt")
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    _ = try access.perform { try engine.exportUserDictionary(name, to: url) }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  func testALearnedWordSurvivesSwitchingProfilesAndComingBack() throws {
    let first = try importLearningProfile(name: "first")
    let second = try importLearningProfile(name: "second")
    XCTAssertNotEqual(first, second)

    let coordinator = RimeDeploymentCoordinator(workspace: workspace, engine: engine)
    _ = try coordinator.deploySync(profileID: first)

    // Teach it a word the dictionary does not contain, so what survives cannot be the fixture.
    try engine.openSession()
    _ = try engine.setInput("shurufa")
    XCTAssertEqual(try engine.candidateList().first?.text, "输入法")
    XCTAssertEqual(try engine.selectCandidate(at: 0).commit, "输入法")
    // Twice, so the count is above the dictionary's own and the survival cannot be the fixture's.
    _ = try engine.setInput("shurufa")
    XCTAssertEqual(try engine.selectCandidate(at: 0).commit, "输入法")
    engine.closeSession()

    XCTAssertTrue(try exportText("tracer").contains("输入法"))
    let database = workspace.userData.appendingPathComponent("tracer.userdb", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))

    // Switch away — which rebinds the engine and deploys the other profile.
    _ = try coordinator.deploySync(profileID: second)
    XCTAssertEqual(try workspace.loadActiveProfile()?.profileID, second)

    // And back. The dictionary was never touched: it belongs to the name "tracer", not to the profile.
    _ = try coordinator.deploySync(profileID: first)
    XCTAssertEqual(try workspace.loadActiveProfile()?.profileID, first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: database.path),
                  "switching profiles must not touch the shared user directory")
    XCTAssertTrue(try exportText("tracer").contains("输入法"),
                  "and the learned word is still in the dictionary afterwards")
    XCTAssertTrue(try engine.userDictionaryNames().contains("tracer"))

    // Removing the old installation must preserve the active profile's shared learned words.
    _ = try coordinator.deploySync(profileID: second)
    try coordinator.delete(profileID: first)
    XCTAssertEqual(try workspace.loadActiveProfile()?.profileID, second)
    XCTAssertNil(try workspace.loadMetadata(for: first))
    XCTAssertTrue(try exportText("tracer").contains("输入法"))
    try engine.openSession()
    _ = try engine.setInput("shurufa")
    XCTAssertEqual(try engine.candidateList().first?.text, "输入法")
    engine.closeSession()
  }

  func testTheSecondProfileSharesTheSameUserDirectory() throws {
    let first = try importLearningProfile(name: "first")
    let second = try importLearningProfile(name: "second")
    let coordinator = RimeDeploymentCoordinator(workspace: workspace, engine: engine)

    _ = try coordinator.deploySync(profileID: first)
    _ = try coordinator.deploySync(profileID: second)

    // Both bindings point at the same user directory: that is what makes the sharing true rather
    // than incidental.
    let firstBinding = RimeBindings.client(workspace: workspace, profileID: first,
                                           buildDirectory: workspace.profile(first).build)
    let secondBinding = RimeBindings.client(workspace: workspace, profileID: second,
                                            buildDirectory: workspace.profile(second).build)
    XCTAssertEqual(firstBinding.userDataDir, secondBinding.userDataDir)
    XCTAssertNotEqual(firstBinding.sharedDataDir, secondBinding.sharedDataDir,
                      "the sources differ; only the user directory is shared")
  }
}
