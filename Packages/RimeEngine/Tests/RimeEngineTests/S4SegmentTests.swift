import XCTest
@testable import RimeEngine

/// S4 §6: the expanded panel's syllable row needs the input *divided*, not guessed, and S3 recorded the row
/// as having no source in this build. It has one: a script translator's preedit is the division. These tests
/// pin what librime actually returns and what `RimeOutput.syllables` accepts as a division.
final class S4SegmentTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL { repositoryRoot.appendingPathComponent("RimeData", isDirectory: true) }

  private func engine() throws -> RimeEngine {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s4-segment", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
    let workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()
    let source = scratch.appendingPathComponent("profile", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file),
                                       to: source.appendingPathComponent(file))
    }
    let engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: tracerData.path,
      prebuiltDataDir: tracerData.appendingPathComponent("build").path,
      userDataDir: workspace.userData.path,
      stagingDir: workspace.staging.path,
      logDir: workspace.log.path)))
    _ = try engine.start()
    let id = try RimeImporter(workspace: workspace, engine: engine)
      .import(payload: source,
              options: RimeImportOptions(displayName: "Segment",
                                         origin: RimeProfileSource(kind: .files))).profileID
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: id)
    return engine
  }

  func testAMultiSyllableInputComesBackDivided() throws {
    let engine = try engine()
    defer { engine.shutdown() }
    try engine.openSession()

    let output = try engine.processKeys("nihaoshijie")
    XCTAssertEqual(output.input, "nihaoshijie", "the raw input is what the client shows")
    XCTAssertEqual(output.preedit, "ni hao shi jie", "librime divides the spelling itself")
    XCTAssertEqual(output.syllables, ["ni", "hao", "shi", "jie"])
  }

  func testASingleSyllableLeavesTheRowEmpty() throws {
    let engine = try engine()
    defer { engine.shutdown() }
    try engine.openSession()

    let output = try engine.processKeys("ni")
    XCTAssertEqual(output.preedit, "ni")
    XCTAssertNil(output.syllables, "one syllable is not a division")
  }

  func testAnUnfinishedSyllableLeavesTheRowEmpty() throws {
    let engine = try engine()
    defer { engine.shutdown() }
    try engine.openSession()

    let output = try engine.processKeys("n")
    XCTAssertEqual(output.preedit, "n")
    XCTAssertNil(output.syllables)
  }

  /// Measured, and it settles the edge: a delimiter the *user* types is kept verbatim in the preedit
  /// ("ni'hao"), so there is no division of ours to show. The row is for the division librime made; the
  /// delimiter is the user's own, and the schema decides which characters count as one.
  func testAHandTypedDelimiterLeavesTheRowEmpty() throws {
    let engine = try engine()
    defer { engine.shutdown() }
    try engine.openSession()

    let output = try engine.processKeys("ni'hao")
    XCTAssertEqual(output.preedit, "ni'hao")
    XCTAssertNil(output.syllables)
  }
}
