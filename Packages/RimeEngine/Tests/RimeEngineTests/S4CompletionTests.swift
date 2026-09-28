import XCTest
@testable import RimeEngine

/// S4-AC1's mechanism, measured on our own data: with 逐码提示 on, the *first letter* produces
/// candidates. The tracer ships it off, which is why its own "n" shows nothing — S4 §2's whole point
/// is that this is a data property, not a UI bug.
///
/// What a real pinyin schema adds on top is a dictionary that can fill the list (S1) and rime-ice's
/// 超级简拼 rule; both are the device run's business. This test settles the half that lives here.
final class S4CompletionTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL { repositoryRoot.appendingPathComponent("RimeData", isDirectory: true) }

  private func engine(completion: Bool, abbreviation: Bool = false) throws -> RimeEngine {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s4-completion", isDirectory: true)
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
    var schema = try String(contentsOf: source.appendingPathComponent("tracer.schema.yaml"),
                            encoding: .utf8)
    schema = schema.replacingOccurrences(of: "enable_completion: false",
                                         with: "enable_completion: " + (completion ? "true" : "false"))
    if abbreviation {
      // rime-ice's 超级简拼: a one-letter input becomes a legitimate abbreviation spelling, so the
      // first letter works even with completion off.
      schema = schema.replacingOccurrences(
        of: "speller:\n  alphabet:",
        with: "speller:\n  algebra:\n    - abbrev/^([a-z]).+$/$1/\n  alphabet:")
    }
    try schema.write(to: source.appendingPathComponent("tracer.schema.yaml"),
                     atomically: true, encoding: .utf8)

    let engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: tracerData.path,
      prebuiltDataDir: tracerData.appendingPathComponent("build").path,
      userDataDir: workspace.userData.path,
      stagingDir: workspace.staging.path,
      logDir: workspace.log.path)))
    _ = try engine.start()
    let id = try RimeImporter(workspace: workspace, engine: engine)
      .import(payload: source,
              options: RimeImportOptions(displayName: "Completion",
                                         origin: RimeProfileSource(kind: .files))).profileID
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: id)
    return engine
  }

  func testTheFirstLetterProducesCandidatesWhenCompletionIsOn() throws {
    let engine = try engine(completion: true)
    defer { engine.shutdown() }
    try engine.openSession()

    let output = try engine.processKeys("n")
    XCTAssertTrue(output.isComposing, "the composition is the typed letter")
    XCTAssertEqual(output.candidates.first?.text, "你",
                   "prefix expansion at the completion penalty — S4 §2's measured row")
    XCTAssertGreaterThan(output.candidates.count, 0)
  }

  /// The other half of S4 §2: completion off leaves the menu empty *unless* the schema has
  /// abbreviation rules, which is what rime-ice relies on.
  func testTheFirstLetterIsEmptyWithCompletionOffAndNoAbbreviations() throws {
    let engine = try engine(completion: false)
    defer { engine.shutdown() }
    try engine.openSession()
    let output = try engine.processKeys("n")
    XCTAssertTrue(output.isComposing)
    XCTAssertTrue(output.candidates.isEmpty, "the tracer's own report: n shows nothing")
  }

  func testAbbreviationsMakeTheFirstLetterWorkWithCompletionOff() throws {
    let engine = try engine(completion: false, abbreviation: true)
    defer { engine.shutdown() }
    try engine.openSession()
    let output = try engine.processKeys("n")
    XCTAssertFalse(output.candidates.isEmpty,
                   "rime-ice's 超级简拼 makes 'n' a real spelling of 'ni' even with completion off")
    XCTAssertEqual(output.candidates.first?.text, "你")
  }

  /// **The bug, and the fix.** A patch has to reach the deployer as one flat key per entry:
  ///
  ///     patch:                                       patch:
  ///       translator/enable_completion: true   vs.     translator:
  ///                                                      enable_completion: true
  ///
  /// The right-hand form is what writing through librime's config API produces, because that API turns a
  /// path into nested maps. Rime's patch semantics replace a map **wholesale**, so the nested form used to
  /// delete `translator/dictionary` along with the key it meant to set — librime logged
  /// `translator/dictionary not specified in schema 'tracer'` and the translator had nothing to look words
  /// up in. The left-hand form merges at the leaf, and the setting takes effect in the same process.
  func testAPatchThroughRimePatchKeepsTheMapItIsWrittenInto() throws {
    let engine = try engine(completion: false)
    defer { engine.shutdown() }

    let patch = RimePatch(engine: engine, configID: "tracer")
    try patch.set(.bool(true), at: "translator/enable_completion")
    let workspace = RimeWorkspace(root: URL(fileURLWithPath: engine.directories.userDataDir)
                                  .deletingLastPathComponent())
    let id = try XCTUnwrap(try workspace.loadActiveProfile()?.profileID)
    let build = workspace.profile(id).build
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: id)

    let deployed = try String(contentsOf: build.appendingPathComponent("tracer.schema.yaml"),
                              encoding: .utf8)
    let translator = deployed.components(separatedBy: "translator:").last ?? ""
    XCTAssertTrue(translator.contains("dictionary: tracer"), "the rest of the map survives the patch")
    XCTAssertTrue(translator.contains("enable_completion: true"), "and the patch arrives")

    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("n").candidates.first?.text, "你",
                   "so the setting is live, which is what S2's 逐码提示 switch needs")
  }

  /// The other half of the contract: the file is the flat form, and the patch API reads it back.
  /// librime cannot address a key that contains a slash — its path syntax splits on it — so the read side
  /// is Arkey's own, and this test is what stops a screen from showing "not set" for every key it wrote.
  func testThePatchFileIsFlatAndReadsBackThroughThePatchAPI() throws {
    let engine = try engine(completion: false)
    defer { engine.shutdown() }

    let patch = RimePatch(engine: engine, configID: "tracer")
    try patch.set(.bool(true), at: "translator/enable_completion")
    try patch.setItem(fromYAML: "switches: [{name: ascii_mode}]\n", sourceKey: "switches",
                      at: "switches")

    let text = try String(contentsOf: patch.patchFileURL, encoding: .utf8)
    XCTAssertTrue(text.contains("\n  translator/enable_completion: true\n"),
                  "one flat key per entry, got: " + text.replacingOccurrences(of: "\n", with: "|"))
    XCTAssertEqual(try patch.userKeys(), ["switches", "translator/enable_completion"])
    XCTAssertEqual(try patch.userValue("translator/enable_completion")?.boolValue, true)
    XCTAssertEqual(try patch.userValue("switches")?.listValue?.count, 1)

    try patch.remove(key: "translator/enable_completion")
    XCTAssertNil(try patch.userValue("translator/enable_completion"), "a reset removes just that key")
    XCTAssertEqual(try patch.userValue("switches")?.listValue?.count, 1, "and not its neighbours")
  }
}
