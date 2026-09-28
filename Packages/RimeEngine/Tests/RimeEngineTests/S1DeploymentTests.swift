import XCTest
@testable import RimeEngine

/// S1 §6 and §7: the deploy swap, the rollback, and what a failed deploy leaves behind.
final class S1DeploymentTests: XCTestCase {
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
      .appendingPathComponent("arkey-s1-deploy", isDirectory: true)
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

  /// One imported profile, ready to deploy. Deliberately the same path the user takes.
  private func importedProfile(name: String = "Tracer") throws -> String {
    let tree = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file),
                                       to: tree.appendingPathComponent(file))
    }
    let importer = RimeImporter(workspace: workspace, engine: engine)
    let outcome = try importer.import(payload: tree,
                                      options: RimeImportOptions(displayName: name,
                                                                 origin: RimeProfileSource(kind: .files)))
    try FileManager.default.removeItem(at: tree)
    return outcome.profileID
  }

  private func coordinator() -> RimeDeploymentCoordinator {
    RimeDeploymentCoordinator(workspace: workspace, engine: engine)
  }

  // MARK: Deploy

  func testDeploySwapsTheBuildAndWritesTheActiveRecord() throws {
    let id = try importedProfile()
    let layout = workspace.profile(id)
    let outcome = try coordinator().deploySync(profileID: id)

    XCTAssertEqual(outcome.generation, 1)
    XCTAssertTrue(outcome.report.succeeded)
    XCTAssertGreaterThan(outcome.buildBytes, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.build.appendingPathComponent("tracer.table.bin").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.buildStaging.path),
                   "the staging directory becomes the build directory in the swap")
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.buildPrevious.path),
                   "the first deploy has no previous generation")

    let active = try XCTUnwrap(try workspace.loadActiveProfile())
    XCTAssertEqual(active.profileID, id)
    XCTAssertEqual(active.generation, 1)
    XCTAssertEqual(active.engineVersion, RimeEngineVersion.pinned)
    XCTAssertTrue(active.sourceDigest?.hasPrefix("sha256:") == true)

    let metadata = try XCTUnwrap(try workspace.loadMetadata(for: id))
    XCTAssertEqual(metadata.deploy?.generation, 1)
    XCTAssertGreaterThan(metadata.stats.buildBytes, 0)
    XCTAssertEqual(metadata.stats.schemaIDs, ["tracer"])

    // The app's engine now types with the deployed profile.
    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("nihao").candidates.first?.text, "你好")
    engine.closeSession()
  }

  /// S1 §6's measured fact, now a signal: librime's staleness check runs once per process, so a second
  /// deploy in the same process recompiles nothing while still reporting success. The generation's file
  /// list cannot tell that apart from a full rebuild — the before/after comparison can, which is what
  /// lets the deploy screen say "already up to date".
  func testASecondDeployInTheSameProcessReportsThatItWroteNothing() throws {
    let id = try importedProfile()
    let first = try coordinator().deploySync(profileID: id)
    XCTAssertTrue(first.report.succeeded)
    XCTAssertFalse(first.report.files.isEmpty, "a fresh deploy produces a generation")
    XCTAssertFalse(first.report.changes.isEmpty,
                   "and it wrote it: " + first.report.changes.written.joined(separator: ", "))
    XCTAssertFalse(first.report.changes.writtenTables.isEmpty,
                   "the compiled tables are what a rebuild writes: "
                     + first.report.changes.written.joined(separator: ", "))

    let second = try coordinator().deploySync(profileID: id)
    XCTAssertTrue(second.report.succeeded)
    XCTAssertFalse(second.report.files.isEmpty, "the generation is still there")
    XCTAssertEqual(second.report.changes.writtenTables, [],
                   "the second deploy in this process compiled no table: "
                     + second.report.changes.written.joined(separator: ", "))
    // The YAML copies are refreshed every run, which is exactly why the signal is about the tables: a
    // "nothing changed" assertion over every file would be false.
    XCTAssertTrue(second.report.changes.written.allSatisfy { $0.hasSuffix(".yaml") },
                  second.report.changes.written.joined(separator: ", "))
  }

  func testRedeployKeepsOnePreviousGeneration() throws {
    let id = try importedProfile()
    let layout = workspace.profile(id)
    _ = try coordinator().deploySync(profileID: id)
    let firstBuildFiles = try FileManager.default.contentsOfDirectory(atPath: layout.build.path)

    let second = try coordinator().deploySync(profileID: id)
    XCTAssertEqual(second.generation, 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.buildPrevious.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.build.appendingPathComponent("tracer.table.bin").path))
    XCTAssertFalse(firstBuildFiles.isEmpty)
    XCTAssertEqual(try workspace.loadActiveProfile()?.generation, 2)
  }

  func testRollbackRestoresThePreviousGeneration() throws {
    let id = try importedProfile()
    let layout = workspace.profile(id)
    _ = try coordinator().deploySync(profileID: id)

    // A marker in the first generation, so the rollback is provably restoring those bytes.
    try Data("generation-one".utf8).write(to: layout.build.appendingPathComponent("marker.txt"))
    _ = try coordinator().deploySync(profileID: id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.build.appendingPathComponent("marker.txt").path),
                   "the second generation is what is live now")

    let rolledBack = try coordinator().rollback(profileID: id)
    XCTAssertEqual(rolledBack.profileID, id)
    XCTAssertEqual(rolledBack.generation, 3)
    XCTAssertEqual(try String(contentsOf: layout.build.appendingPathComponent("marker.txt"), encoding: .utf8),
                   "generation-one")
    XCTAssertEqual(try workspace.loadActiveProfile()?.generation, 3)
    XCTAssertTrue(try workspace.loadMetadata(for: id)?.deploy?.warnings.contains {
      $0.contains("rolled back")
    } == true)

    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("nihao").candidates.first?.text, "你好",
                   "the restored generation types")
    engine.closeSession()
  }

  func testRollbackWithoutAPreviousGenerationIsRefused() throws {
    let id = try importedProfile()
    _ = try coordinator().deploySync(profileID: id)
    XCTAssertThrowsError(try coordinator().rollback(profileID: id)) { error in
      guard case RimeDeploymentFailure.rollbackUnavailable = error else {
        return XCTFail("expected rollbackUnavailable, got \(error)")
      }
    }
  }

  func testAFailedDeployKeepsThePreviousGenerationTyping() throws {
    let id = try importedProfile()
    let layout = workspace.profile(id)
    _ = try coordinator().deploySync(profileID: id)
    let activeBefore = try XCTUnwrap(try workspace.loadActiveProfile())

    // Break the profile the way a bad edit would: schema_list names one more schema than the
    // config contains. tracer still deploys; ghost cannot.
    try "config_version: \"1\"\nschema_list:\n  - schema: tracer\n  - schema: ghost\n"
      .write(to: layout.source.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try coordinator().deploySync(profileID: id)) { error in
      guard case RimeDeploymentFailure.deployFailed(let report) = error else {
        return XCTFail("expected deployFailed, got \(error)")
      }
      XCTAssertFalse(report.succeeded)
      XCTAssertNotNil(report.failureReason)
    }

    XCTAssertEqual(try workspace.loadActiveProfile()?.generation, activeBefore.generation,
                   "a failed deploy does not move the active pointer")
    XCTAssertTrue(layout.buildIsUsable(layout.build), "the previous generation is still there")
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.buildStaging.path),
                  "staging stays for diagnosis; the janitor removes it at next launch")

    // And it still types: the previous generation's tables plus the sources, which still hold the
    // schema that worked.
    _ = try engine.rebind(to: RimeBindings.client(workspace: workspace, profileID: id,
                                                  buildDirectory: layout.build))
    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("nihao").candidates.first?.text, "你好")
    engine.closeSession()

    // The next launch's janitor clears the failed staging directory (§3).
    let outcome = RimeWorkspaceJanitor().run(workspace: workspace)
    XCTAssertEqual(outcome.removedBuildStaging, [id])
  }

  // MARK: Library

  func testTwoProfilesCoexistAndActivationSwitchesBetweenThem() throws {
    let first = try importedProfile(name: "First")
    let second = try importedProfile(name: "Second")
    XCTAssertNotEqual(first, second)

    _ = try coordinator().deploySync(profileID: first)
    XCTAssertEqual(try workspace.loadActiveProfile()?.profileID, first)

    _ = try coordinator().deploySync(profileID: second)
    let switched = try XCTUnwrap(try workspace.loadActiveProfile())
    XCTAssertEqual(switched.profileID, second)
    XCTAssertEqual(switched.previousProfileID, first,
                   "the record says where the user came from, which is what makes switching reversible")

    // Nothing about the first profile was touched by activating the second.
    XCTAssertTrue(workspace.profile(first).buildIsUsable(workspace.profile(first).build))
    _ = try coordinator().activate(profileID: first)
    XCTAssertEqual(try workspace.loadActiveProfile()?.profileID, first)

    let library = try coordinator().library()
    XCTAssertEqual(library.map(\.id).sorted(), [first, second].sorted())
    XCTAssertEqual(library.map(\.displayName).sorted(), ["First", "Second"])
  }

  func testDeletingAProfileThroughTheLibraryKeepsItsDictionaries() throws {
    let id = try importedProfile()
    _ = try coordinator().deploySync(profileID: id)
    let database = workspace.userData.appendingPathComponent("tracer.userdb", isDirectory: true)
    try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)

    try coordinator().delete(profileID: id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.profile(id).directory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: database.path),
                  "the dictionary belongs to a dictionary name, so deleting a profile keeps it unless asked")
    XCTAssertNil(try workspace.loadActiveProfile())
  }

  func testDeployingAProfileThatIsNotThereIsANamedError() throws {
    XCTAssertThrowsError(try coordinator().deploySync(profileID: "ghost")) { error in
      guard case RimeDeploymentFailure.profileNotFound(let id) = error else {
        return XCTFail("expected profileNotFound, got \(error)")
      }
      XCTAssertEqual(id, "ghost")
    }
  }
}
