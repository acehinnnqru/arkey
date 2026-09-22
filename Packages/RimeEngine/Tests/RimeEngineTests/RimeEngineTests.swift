import XCTest
@testable import RimeEngine

final class RimeEngineTests: XCTestCase {
  /// Packages/RimeEngine/Tests/RimeEngineTests/<this file> -> repository root
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func makeScratchDirectories() throws -> RimeDirectories {
    let fileManager = FileManager.default
    let scratch = fileManager.temporaryDirectory
      .appendingPathComponent("arkey-engine-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let staging = scratch.appendingPathComponent("staging", isDirectory: true)
    let user = scratch.appendingPathComponent("user", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: user, withIntermediateDirectories: true)
    return RimeDirectories(sharedDataDir: repositoryRoot.appendingPathComponent("RimeData").path,
                           prebuiltDataDir: staging.path,
                           userDataDir: user.path,
                           stagingDir: staging.path,
                           logDir: user.appendingPathComponent("log", isDirectory: true).path)
  }

  func testLibrimeVersion() {
    XCTAssertEqual(RimeEngine.librimeVersion, "1.17.0")
  }

  /// The tracer's whole reason to exist: deploy the schema, type nihao, commit 你好.
  func testDeployComposeAndCommit() async throws {
    let directories = try makeScratchDirectories()
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))

    let started = try await engine.start()
    XCTAssertNotNil(started.milliseconds)

    let maintenance = try await engine.runMaintenance(fullCheck: true)
    XCTAssertNotNil(maintenance.milliseconds)

    try await engine.openSession()

    var output = try await engine.processKeys("nihao")
    XCTAssertTrue(output.isComposing, "expected an active composition after typing nihao")
    XCTAssertEqual(output.preedit, "ni hao")
    XCTAssertEqual(output.candidates.first?.text, "你好")

    output = try await engine.selectCandidate(at: 0)
    XCTAssertEqual(output.commit, "你好")

    let settled = try await engine.processKeys("")
    XCTAssertFalse(settled.isComposing, "composition should be gone after committing")

    await engine.shutdown()
  }
}
