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

  /// The launch timeline leans on this to separate "dyld" from "our code".
  func testProcessAgeIsReportedByTheKernel() {
    guard let age = RimeProbe.processAgeSeconds() else {
      XCTFail("the kernel did not report this process's start time")
      return
    }
    XCTAssertGreaterThan(age, 0)
    XCTAssertLessThan(age, 3600)
  }

  /// The tracer's whole reason to exist: deploy the schema, type nihao, commit 你好.
  func testDeployComposeAndCommit() throws {
    let directories = try makeScratchDirectories()
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))

    let started = try engine.start()
    XCTAssertNotNil(started.milliseconds)

    let maintenance = try engine.runMaintenance(fullCheck: true)
    XCTAssertNotNil(maintenance.milliseconds)

    try engine.openSession()

    var output = try engine.processKeys("nihao")
    XCTAssertTrue(output.isComposing, "expected an active composition after typing nihao")
    XCTAssertEqual(output.preedit, "ni hao")
    XCTAssertEqual(output.candidates.first?.text, "你好")

    output = try engine.selectCandidate(at: 0)
    XCTAssertEqual(output.commit, "你好")

    let settled = try engine.processKeys("")
    XCTAssertFalse(settled.isComposing, "composition should be gone after committing")

    engine.shutdown()
  }

  /// The keyboard types a character literally when librime declines the key. This is the
  /// precondition for that fallback: the tracer schema ships no punctuator, so "." is declined
  /// outright, and without the fallback the key did nothing at all.
  func testSchemaDeclinesPunctuation() throws {
    let directories = try makeScratchDirectories()
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.start()
    _ = try engine.runMaintenance(fullCheck: true)
    try engine.openSession()

    let output = try engine.processKey(RimeKey.ascii(".") ?? 0x2E)
    XCTAssertFalse(output.handled, "a punctuator-less schema should decline '.'")
    XCTAssertTrue((output.commit ?? "").isEmpty)
    XCTAssertFalse(output.isComposing)

    engine.shutdown()
  }

  /// The space key is the primary commit path, and what it produces depends on the dictionary.
  /// Measured, not assumed: an exact entry commits that entry, and an input with no entry at all
  /// comes back as the raw letters, which is what a user sees as "no Chinese came out".
  func testSpaceCommitsTheCandidateOrTheRawInput() throws {
    let directories = try makeScratchDirectories()
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.start()
    _ = try engine.runMaintenance(fullCheck: true)
    try engine.openSession()

    // Exact entry: space commits it.
    var output = try engine.processKeys("shurufa")
    XCTAssertEqual(output.candidates.first?.text, "输入法")
    output = try engine.processKey(RimeKey.space)
    XCTAssertEqual(output.commit, "输入法")

    // No entry at all: the composition is still there and space hands the raw input back.
    output = try engine.processKeys("woaini")
    XCTAssertTrue(output.candidates.isEmpty)
    XCTAssertTrue(output.isComposing)
    output = try engine.processKey(RimeKey.space)
    XCTAssertEqual(output.commit, "woaini")

    engine.shutdown()
  }
}
