import XCTest
@testable import RimeEngine

/// S1 §9's last clause: every degraded activation names itself and the repair the user has to make. The
/// table is what the keyboard's status line and the app's banner both read, so this is where the two are
/// kept from disagreeing.
final class S1RecoveryTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL { repositoryRoot.appendingPathComponent("RimeData", isDirectory: true) }

  private func makeWorkspace(_ name: String) throws -> RimeWorkspace {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s1-recovery", isDirectory: true)
      .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try RimeWorkspace(root: root).createDirectories()
  }

  /// A profile that looks deployed, with or without a usable build and a previous generation.
  private func installProfile(_ workspace: RimeWorkspace, id: String,
                              withBuild: Bool, withPrevious: Bool) throws {
    let layout = workspace.profile(id)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: layout.source, withIntermediateDirectories: true)
    try fileManager.copyItem(at: tracerData.appendingPathComponent("tracer.dict.yaml"),
                             to: layout.source.appendingPathComponent("tracer.dict.yaml"))
    if withBuild {
      try fileManager.createDirectory(at: layout.build, withIntermediateDirectories: true)
      try Data("table".utf8).write(to: layout.build.appendingPathComponent("tracer.table.bin"))
    }
    if withPrevious {
      try fileManager.createDirectory(at: layout.buildPrevious, withIntermediateDirectories: true)
      try Data("previous".utf8).write(to: layout.buildPrevious.appendingPathComponent("tracer.prism.bin"))
    }
    try workspace.writeActiveProfile(RimeActiveProfile(profileID: id, generation: 1))
  }

  private func resolve(_ workspace: RimeWorkspace, appGroup: Bool = true) -> RimeResolvedProfile {
    RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData,
                                  appGroupAvailable: appGroup)
  }

  func testAProfileThatRunsHasNothingToRecover() throws {
    let workspace = try makeWorkspace("healthy")
    try installProfile(workspace, id: "tracer-1", withBuild: true, withPrevious: false)

    let resolved = resolve(workspace)
    XCTAssertNil(resolved.fallbackReason)
    XCTAssertNil(RimeProfileRecovery.of(resolved), "a profile that is running needs no repair message")
  }

  func testFallingBackToThePreviousGenerationAsksForADeploy() throws {
    let workspace = try makeWorkspace("previous")
    try installProfile(workspace, id: "tracer-1", withBuild: false, withPrevious: true)

    let recovery = try XCTUnwrap(RimeProfileRecovery.of(resolve(workspace)))
    XCTAssertEqual(recovery.action, .deploy)
    XCTAssertEqual(recovery.reason, "the active build is missing or empty; using build.previous")
    XCTAssertTrue(recovery.message.contains("重新部署"), recovery.message)
  }

  func testAProfileWithNoUsableBuildAsksForADeploy() throws {
    let workspace = try makeWorkspace("empty")
    try installProfile(workspace, id: "tracer-1", withBuild: false, withPrevious: false)

    let recovery = try XCTUnwrap(RimeProfileRecovery.of(resolve(workspace)))
    XCTAssertEqual(recovery.action, .deploy)
    XCTAssertEqual(recovery.reason, "profile 'tracer-1' has no usable build")
    XCTAssertTrue(recovery.message.contains("重新部署"), recovery.message)
  }

  func testNoActiveProfileAsksTheUserToChooseOne() throws {
    let workspace = try makeWorkspace("empty-active")

    let recovery = try XCTUnwrap(RimeProfileRecovery.of(resolve(workspace)))
    XCTAssertEqual(recovery.action, .chooseProfile)
    XCTAssertEqual(recovery.reason, "no active.json")
    XCTAssertTrue(recovery.message.contains("导入或选择配置"), recovery.message)
  }

  func testAnUnreachableAppGroupIsExplainedRatherThanGuessed() throws {
    let workspace = try makeWorkspace("no-group")
    try installProfile(workspace, id: "tracer-1", withBuild: true, withPrevious: false)

    let recovery = try XCTUnwrap(RimeProfileRecovery.of(resolve(workspace, appGroup: false)))
    XCTAssertEqual(recovery.action, .chooseProfile)
    XCTAssertEqual(recovery.reason, "the app group is unreachable")
  }

  /// The button the banner shows is the action's own label, so a new action cannot reach the UI without
  /// one, and the keyboard's message and the app's button cannot describe the same repair differently.
  func testEachActionCarriesTheLabelTheButtonShows() throws {
    XCTAssertEqual(RimeProfileRecovery.Action.deploy.title, "重新部署")
    XCTAssertEqual(RimeProfileRecovery.Action.chooseProfile.title, "导入或选择配置")
  }
}
