import XCTest
@testable import RimeEngine

/// The app's whole documented flow on one workspace, engine-side. Every piece has a unit test; this is the one
/// that runs them in the order the app runs them — bootstrap, import, deploy, activate, the keyboard appearing,
/// typing, a setting, another deploy, the launch janitor — because that order is where the cross-component
/// mistakes live, and no device is needed to find them.
final class S1AppFlowTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL { repositoryRoot.appendingPathComponent("RimeData", isDirectory: true) }

  func testTheAppsDocumentedFlowOnOneWorkspace() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-app-flow", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }

    // 1. Bootstrap, as the app does it: directories, the installation record, the storage policy.
    let workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()
    // The app has its own helper for this path; the test uses the same directory shape.
    let sync = scratch.appendingPathComponent("sync", isDirectory: true)
    try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
    _ = try workspace.seedInstallation(syncDirectory: sync)
    try workspace.applyStoragePolicy()

    // 2. Resolve and start the engine against the resolved directories (what the app binds).
    let resolved = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
    let engine = RimeEngine(configuration: RimeConfiguration(directories: resolved.directories))
    defer { engine.shutdown() }
    _ = try engine.start()

    // 3. Import the tracer from a folder, then deploy and activate it (the 配置库 path).
    let source = scratch.appendingPathComponent("profile", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file),
                                       to: source.appendingPathComponent(file))
    }
    let id = try RimeImporter(workspace: workspace, engine: engine)
      .import(payload: source,
              options: RimeImportOptions(displayName: "App flow",
                                         origin: RimeProfileSource(kind: .files))).profileID
    // S2-AC2, empirically: the digest of the *source* right after the import, to compare with the end of the
    // flow. The unit test asserts one patch write does not touch the shipped file; this asserts that nothing in
    // the whole flow — deploy, activate, patch, redeploy, janitor — does.
    let sourceDigest = RimeDigest.sha256(ofTree: workspace.profile(id).source)

    let coordinator = RimeDeploymentCoordinator(workspace: workspace, engine: engine)
    let deployed = try coordinator.deploySync(profileID: id)
    XCTAssertTrue(deployed.report.succeeded, deployed.report.failureReason ?? "")
    XCTAssertEqual(try workspace.loadActiveProfile()?.profileID, id, "the deploy activated it")

    // 4. The keyboard appears: resolve again and let the adoption rule decide.
    let next = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: resolved, isComposing: false),
                   .rebind(next))
    // S1 §10's clause for this step: the rebind happens "and active.json is not involved". The pointer is the
    // app's record of what is deployed; a keyboard adopting a change must not rewrite it, and the bytes are the
    // evidence — the resolver read it, the rebind did not touch it.
    let pointerBefore = try Data(contentsOf: workspace.activeRecord)
    _ = try engine.rebind(to: next.directories)
    XCTAssertEqual(try Data(contentsOf: workspace.activeRecord), pointerBefore,
                   "the rebind rewrote active.json, which only the app's own activation may do")

    // 5. Type. The tracer's 你好 is the first candidate for nihao and commits as one word.
    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("nihao").candidates.first?.text, "你好")
    XCTAssertEqual(try engine.selectCandidate(at: 0).commit, "你好")
    engine.closeSession()

    // 6. A setting, then another deploy (S2's route: patch, deploy, the change is in the deployed schema).
    try RimePatch(engine: engine, configID: "tracer")
      .set(.bool(true), at: "translator/enable_completion")
    let redeployed = try coordinator.deploySync(profileID: id)
    XCTAssertTrue(redeployed.report.succeeded, redeployed.report.failureReason ?? "")
    XCTAssertEqual(try engine.withSchemaConfig("tracer") { $0.bool("translator/enable_completion") },
                   true, "the patch reached the deployed schema")

    // 7. The next launch's janitor finds nothing to repair, which is what "clean" means.
    let janitor = RimeWorkspaceJanitor().run(workspace: workspace)
    XCTAssertTrue(janitor.removedStagingEntries.isEmpty, janitor.notes.joined(separator: "; "))
    XCTAssertTrue(janitor.restoredBuilds.isEmpty, janitor.notes.joined(separator: "; "))
    XCTAssertTrue(janitor.removedBuildStaging.isEmpty, janitor.notes.joined(separator: "; "))

    XCTAssertEqual(RimeDigest.sha256(ofTree: workspace.profile(id).source), sourceDigest,
                   "S2-AC2: nothing in the flow may modify the shipped sources")
  }
}
