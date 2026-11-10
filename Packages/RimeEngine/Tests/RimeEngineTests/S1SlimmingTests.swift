import XCTest
@testable import RimeEngine

/// S1 §12's lite install: dropping an import table from a profile, with the result verified before it
/// is accepted.
final class S1SlimmingTests: XCTestCase {
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
  private var engine: RimeEngine!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s1-slim", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: tracerData.path,
      prebuiltDataDir: tracerData.appendingPathComponent("build").path,
      userDataDir: scratch.appendingPathComponent("user").path,
      stagingDir: scratch.appendingPathComponent("staging").path,
      logDir: scratch.appendingPathComponent("log").path)))
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    try? FileManager.default.removeItem(at: scratch)
  }

  @discardableResult
  private func makeSource(name: String = "source") throws -> URL {
    let source = scratch.appendingPathComponent(name, isDirectory: true)
    let fileManager = FileManager.default
    for directory in ["cn_dicts", "en_dicts"] {
      try fileManager.createDirectory(at: source.appendingPathComponent(directory, isDirectory: true),
                                      withIntermediateDirectories: true)
    }
    for file in ["default.yaml", "tracer.schema.yaml"] {
      try fileManager.copyItem(at: tracerData.appendingPathComponent(file),
                               to: source.appendingPathComponent(file))
    }
    try """
    ---
    name: tracer
    version: "0.1"
    import_tables:
      # The embedding table upstream warns about.
      - cn_dicts/tencent
      - cn_dicts/base
      - en_dicts/en
    ...
    """.write(to: source.appendingPathComponent("tracer.dict.yaml"), atomically: true, encoding: .utf8)
    for path in ["cn_dicts/tencent.dict.yaml", "cn_dicts/base.dict.yaml", "en_dicts/en.dict.yaml"] {
      try """
      ---
      name: \(path)
      ...
      """.write(to: source.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    return source
  }

  func testRemovingATableRewritesTheImportsAndDeletesTheFile() throws {
    let source = try makeSource()
    let result = try RimeProfileSlimming.removeImportTables(["cn_dicts/tencent"], from: source,
                                                            engine: engine)

    XCTAssertEqual(result.removedFiles, ["cn_dicts/tencent.dict.yaml"])
    XCTAssertEqual(result.rewrittenFiles, ["tracer.dict.yaml"])
    XCTAssertTrue(result.missingTables.isEmpty, result.summary)

    let text = try String(contentsOf: source.appendingPathComponent("tracer.dict.yaml"), encoding: .utf8)
    XCTAssertFalse(text.contains("tencent"), text)
    XCTAssertTrue(text.contains("- cn_dicts/base"), "the other imports stay")
    XCTAssertTrue(text.contains("- en_dicts/en"))
    XCTAssertTrue(text.contains("# The embedding table upstream warns about."),
                  "the comment stays: it is the author's, and the entry it described is gone")
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: source.appendingPathComponent("cn_dicts/tencent.dict.yaml").path))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: source.appendingPathComponent("cn_dicts/base.dict.yaml").path))
  }

  /// The names Rime accepts in `import_tables` are written several ways; all of them match.
  func testTableNamesAreMatchedInTheFormsRimeAccepts() throws {
    for (index, name) in ["cn_dicts/tencent", "./cn_dicts/tencent", "cn_dicts/tencent.dict.yaml"].enumerated() {
      // Each attempt starts from a fresh copy, because the first one deletes the file.
      let fresh = try makeSource(name: "source-\(index)")
      let result = try RimeProfileSlimming.removeImportTables([name], from: fresh, engine: engine)
      XCTAssertEqual(result.removedFiles, ["cn_dicts/tencent.dict.yaml"], "for \(name)")
      XCTAssertTrue(result.missingTables.isEmpty, "for \(name): \(result.summary)")
      let text = try String(contentsOf: fresh.appendingPathComponent("tracer.dict.yaml"), encoding: .utf8)
      XCTAssertFalse(text.contains("tencent"), "for \(name)")
    }
  }

  func testATableTheProfileDoesNotHaveIsReported() throws {
    let source = try makeSource()
    let result = try RimeProfileSlimming.removeImportTables(["cn_dicts/nowhere"], from: source,
                                                            engine: engine)
    XCTAssertEqual(result.missingTables, ["cn_dicts/nowhere"])
    XCTAssertTrue(result.removedFiles.isEmpty)
    XCTAssertTrue(result.rewrittenFiles.isEmpty)
  }

  func testCommentedAndQuotedImportsAreRemovedBeforeValidation() throws {
    let entries = [
      "cn_dicts/tencent  # Large dictionary; slow deployment",
      "'cn_dicts/tencent' # Large dictionary",
      "\"./cn_dicts/tencent.dict.yaml\" # Large dictionary",
      "{ table: cn_dicts/tencent } # Large dictionary",
    ]
    for (index, entry) in entries.enumerated() {
      let source = try makeSource(name: "commented-\(index)")
      let url = source.appendingPathComponent("tracer.dict.yaml")
      let original = try String(contentsOf: url, encoding: .utf8)
        .replacingOccurrences(of: "import_tables:", with: "import_tables:   # Dictionary imports")
        .replacingOccurrences(of: "- cn_dicts/tencent", with: "- " + entry)
      try original.write(to: url, atomically: true, encoding: .utf8)

      let result = try RimeProfileSlimming.removeImportTables(["cn_dicts/tencent"], from: source,
                                                              engine: engine)
      XCTAssertEqual(result.removedFiles, ["cn_dicts/tencent.dict.yaml"], entry)
      XCTAssertEqual(result.rewrittenFiles, ["tracer.dict.yaml"], entry)
      XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
        original.replacingOccurrences(of: "  - " + entry + "\n", with: ""), entry)
      let validation = RimeConfigValidation.validate(source: source, engine: engine)
      XCTAssertTrue(validation.isAcceptable, String(describing: validation.errors))
    }
  }

  /// A rewrite that librime would not read is refused, and the file is left exactly as it was.
  func testAFailedVerificationLeavesTheFileUntouched() throws {
    let source = try makeSource()
    let broken = """
    ---
    name: tracer
    import_tables:
      - cn_dicts/tencent
    \tbad: indentation
    ...
    """
    let url = source.appendingPathComponent("tracer.dict.yaml")
    try broken.write(to: url, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try RimeProfileSlimming.removeImportTables(["cn_dicts/tencent"], from: source,
                                                                    engine: engine)) { error in
      guard case RimeSlimmingError.verificationFailed(let path, _) = error else {
        return XCTFail("expected verificationFailed, got \(error)")
      }
      XCTAssertEqual(path, "tracer.dict.yaml")
    }
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken,
                   "a rejected rewrite must leave the file untouched")
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: source.appendingPathComponent("cn_dicts/tencent.dict.yaml").path),
                  "and must not delete the table it could not remove")
  }

  /// The slimmed source still deploys and types, which is the point of doing this at all.
  func testASlimmedProfileStillDeploysAndTypes() throws {
    let workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()
    // A source that is the tracer plus one import: what a slimmed rime-ice looks like in miniature.
    let source = try makeSource(name: "deployable")
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      let target = source.appendingPathComponent(file)
      try FileManager.default.removeItem(at: target)
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file), to: target)
    }
    let dictionaryURL = source.appendingPathComponent("tracer.dict.yaml")
    let text = try String(contentsOf: dictionaryURL, encoding: .utf8)
    let withImport = text.replacingOccurrences(
      of: "name: tracer",
      with: "name: tracer\nimport_tables:\n  - cn_dicts/base  # Large dictionary")
    XCTAssertNotEqual(withImport, text, "the fixture dictionary must name the table")
    try withImport.write(to: dictionaryURL, atomically: true, encoding: .utf8)

    let importer = RimeImporter(workspace: workspace, engine: engine)
    let outcome = try importer.import(payload: source,
                                      options: RimeImportOptions(displayName: "Slim",
                                        origin: RimeProfileSource(kind: .files),
                                        removedImportTables: ["cn_dicts/base"]))
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine)
      .deploySync(profileID: outcome.profileID)
    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("nihao").candidates.first?.text, "你好")
  }
}
