import XCTest
@testable import RimeEngine

/// S2 §8's macOS list: the patch round trip, reset, list replacement, 模糊音 composition and revert.
final class S2PatchTests: XCTestCase {
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
  private var profileID: String!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s2-patch", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()

    let source = scratch.appendingPathComponent("profile", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file),
                                       to: source.appendingPathComponent(file))
    }
    let directories = RimeDirectories(sharedDataDir: tracerData.path,
                                      prebuiltDataDir: tracerData.appendingPathComponent("build").path,
                                      userDataDir: workspace.userData.path,
                                      stagingDir: workspace.staging.path,
                                      logDir: workspace.log.path)
    engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.start()

    let importer = RimeImporter(workspace: workspace, engine: engine)
    profileID = try importer.import(payload: source,
                                    options: RimeImportOptions(displayName: "Tracer",
                                                               origin: RimeProfileSource(kind: .files))).profileID
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: profileID)
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    try? FileManager.default.removeItem(at: scratch)
  }

  private var patch: RimePatch { RimePatch(engine: engine, configID: "default") }

  private func redeploy() throws {
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: profileID)
  }

  /// A second schema in the profile, deployed but not enabled: the 方案 screen's "turn it on" case.
  private func installSecondSchema() throws {
    let source = workspace.profile(profileID).source
    let schema = try String(contentsOf: source.appendingPathComponent("tracer.schema.yaml"),
                            encoding: .utf8)
    try schema
      .replacingOccurrences(of: "schema_id: tracer", with: "schema_id: shuangpin")
      .replacingOccurrences(of: "name: Tracer", with: "name: Shuangpin")
      .replacingOccurrences(of: "dictionary: tracer", with: "dictionary: shuangpin")
      .write(to: source.appendingPathComponent("shuangpin.schema.yaml"),
             atomically: true, encoding: .utf8)
    try FileManager.default.copyItem(at: source.appendingPathComponent("tracer.dict.yaml"),
                                     to: source.appendingPathComponent("shuangpin.dict.yaml"))
    try redeploy()
  }

  // MARK: The write path

  func testAPatchWriteTouchesOnlyTheCustomFile() throws {
    let sourceBefore = try Data(contentsOf: workspace.profile(profileID).source
      .appendingPathComponent("default.yaml"))

    let change = try patch.set(.int(7), at: "menu/page_size")
    XCTAssertEqual(change.key, "menu/page_size")
    XCTAssertNil(change.oldValue)
    XCTAssertEqual(change.newValue?.intValue, 7)

    let text = try String(contentsOf: patch.patchFileURL, encoding: .utf8)
    XCTAssertTrue(text.contains("patch:"), text)
    XCTAssertTrue(text.contains("page_size"), text)

    let sourceAfter = try Data(contentsOf: workspace.profile(profileID).source
      .appendingPathComponent("default.yaml"))
    XCTAssertEqual(sourceBefore, sourceAfter, "S2-AC2: a shipped file is never modified")

    try redeploy()
    XCTAssertEqual(try engine.withConfig("default") { $0.int("menu/page_size") }, 7)
  }

  func testUnrelatedKeysInTheSamePatchSurvive() throws {
    try patch.set(.int(3), at: "menu/page_size")
    try patch.set(.bool(true), at: "style/ascii_punct")

    try patch.set(.int(9), at: "menu/page_size")
    try redeploy()

    XCTAssertEqual(try engine.withConfig("default") { $0.int("menu/page_size") }, 9)
    XCTAssertEqual(try engine.withConfig("default") { $0.bool("style/ascii_punct") }, true,
                   "a second write must not drop the key the first one wrote")
    XCTAssertEqual(try patch.userKeys().sorted(), ["menu/page_size", "style/ascii_punct"])
  }

  func testResetRestoresTheSchemasOwnValue() throws {
    XCTAssertEqual(try engine.withConfig("default") { $0.int("menu/page_size") }, 5)
    try patch.set(.int(9), at: "menu/page_size")
    try redeploy()
    XCTAssertEqual(try engine.withConfig("default") { $0.int("menu/page_size") }, 9)

    let change = try patch.remove(key: "menu/page_size")
    XCTAssertEqual(change.oldValue?.intValue, 9)
    XCTAssertNil(try patch.userValue("menu/page_size"))
    try redeploy()
    XCTAssertEqual(try engine.withConfig("default") { $0.int("menu/page_size") }, 5,
                   "reset is the schema's value, not our idea of a default")
  }

  func testRemovingEveryKeyAlsoRemovesTheFile() throws {
    try patch.set(.int(7), at: "menu/page_size")
    XCTAssertTrue(FileManager.default.fileExists(atPath: patch.patchFileURL.path))
    try patch.removeAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: patch.patchFileURL.path),
                   "an empty patch file says nothing; resetting a screen means deleting it")
  }

  // MARK: Snapshot and revert

  func testSnapshotAndRestoreBringThePatchBack() throws {
    try patch.set(.int(7), at: "menu/page_size")
    let snapshot = try XCTUnwrap(try patch.snapshot(into: workspace.patchesBackup))

    try patch.set(.int(11), at: "menu/page_size")
    XCTAssertEqual(try patch.userValue("menu/page_size")?.intValue, 11)

    XCTAssertTrue(try patch.restore(from: snapshot))
    XCTAssertEqual(try patch.userValue("menu/page_size")?.intValue, 7,
                   "S2-AC4: revert is one action, and it is the file we wrote before the change")

    // A patch that breaks the deploy: measured, an unparseable patch file is tolerated (librime
    // logs and carries on), but a schema_list naming a schema the profile does not have fails it.
    try "patch:\n  schema_list:\n    - schema: ghost\n"
      .write(to: patch.patchFileURL, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try redeploy()) { error in
      guard case RimeDeploymentFailure.deployFailed(let report) = error else {
        return XCTFail("expected deployFailed, got \(error)")
      }
      XCTAssertFalse(report.succeeded)
      XCTAssertNotNil(report.failureReason)
      // S2 §5.6: the deploy screen shows librime's own words about the schema it could not build.
      XCTAssertTrue(report.logText.contains("ghost"), report.logText)
    }
    XCTAssertTrue(workspace.profile(profileID).buildIsUsable(workspace.profile(profileID).build))
    XCTAssertTrue(try patch.restore(from: snapshot))
    try redeploy()
    XCTAssertEqual(try engine.withConfig("default") { $0.int("menu/page_size") }, 7)
  }

  // MARK: Lists

  func testSchemaListWritesAsAWholeListAndRefusesUnknownIDs() throws {
    let editor = RimeSchemaListEditor(engine: engine)
    try engine.openSession()
    XCTAssertEqual(try editor.effective(), ["tracer"])

    let change = try editor.write(["tracer"])
    XCTAssertEqual(change.newValue?.listValue?.count, 1)
    try redeploy()
    XCTAssertEqual(try editor.effective(), ["tracer"])

    XCTAssertThrowsError(try editor.write(["tracer", "ghost"])) { error in
      guard case RimePatchError.schemaNotInProfile(let id) = error else {
        return XCTFail("expected schemaNotInProfile, got \(error)")
      }
      XCTAssertEqual(id, "ghost")
    }
    // The refused write did not half-apply.
    XCTAssertEqual(try editor.effective(), ["tracer"])
  }

  /// S2 §8's list replacement: enable, order and default are the whole `schema_list`, and applying
  /// the same edit twice leaves the file alone.
  func testSchemaOrderAndDefaultAreTheListOrder() throws {
    try installSecondSchema()
    let installed = RimeTreeClassifier.classify(root: workspace.profile(profileID).source).schemaIDs
    let editor = RimeSchemaListEditor(engine: engine, installed: installed)

    // librime's own list names what is on, not what the profile has: the difference is the toggle.
    XCTAssertEqual(try engine.schemaIDs(), ["tracer"], "only the enabled schema is deployed")
    XCTAssertEqual(try editor.effective(), ["tracer"], "and only it is in the list")
    XCTAssertEqual(try editor.available().sorted(), ["shuangpin", "tracer"], "both are offered")

    try editor.write(["tracer", "shuangpin"])
    try redeploy()
    XCTAssertEqual(try editor.effective(), ["tracer", "shuangpin"])

    let patchURL = editor.patch.patchFileURL
    try editor.write(["shuangpin", "tracer"])
    let fileAfterReorder = try Data(contentsOf: patchURL)
    try redeploy()
    XCTAssertEqual(try editor.effective(), ["shuangpin", "tracer"], "the order the user set")
    let deployedFirst = try engine.withConfig("default") {
      $0.value("schema_list")?.listValue?.first?.mapValue?["schema"]?.stringValue
    }
    XCTAssertEqual(deployedFirst, "shuangpin", "the first entry is the default (S2 §3)")

    // The same edit twice is one write: the file already says what the user asked for.
    try editor.write(["shuangpin", "tracer"])
    XCTAssertEqual(try Data(contentsOf: patchURL), fileAfterReorder)

    // Turning one off writes a subset of the deployed list, which is allowed.
    try editor.write(["tracer"])
    try redeploy()
    XCTAssertEqual(try editor.effective(), ["tracer"])
  }

  // MARK: 模糊音

  func testFuzzyPinyinCompositionIsIdempotentAndReversible() {
    let base = ["xform/^([a-z]+)$/$1/", "abbrev/^([a-z]).+$/$1/"]

    let once = RimeFuzzyPinyin.compose(baseAlgebra: base, enabled: ["zh_z", "an_ang"])
    let twice = RimeFuzzyPinyin.compose(baseAlgebra: once, enabled: ["zh_z", "an_ang"])
    XCTAssertEqual(once, twice, "composing twice must not accumulate rules")

    XCTAssertEqual(once.filter { $0 == "derive/^zh/z/" }.count, 1)
    XCTAssertTrue(once.contains("derive/an$/ang/"))
    XCTAssertEqual(Array(once.suffix(base.count)), base, "the schema's own rules stay, in order")

    let afterDisabling = RimeFuzzyPinyin.compose(baseAlgebra: once, enabled: ["zh_z"])
    XCTAssertTrue(afterDisabling.contains("derive/^zh/z/"))
    XCTAssertFalse(afterDisabling.contains("derive/an$/ang/"),
                   "disabling one preset removes only its rules")
    XCTAssertEqual(Array(afterDisabling.suffix(base.count)), base)

    XCTAssertEqual(RimeFuzzyPinyin.compose(baseAlgebra: base, enabled: []), base)

    // The screen reads back what it wrote.
    XCTAssertEqual(RimeFuzzyPinyin.enabledPresets(in: once).sorted(), ["an_ang", "zh_z"])
    XCTAssertEqual(RimeFuzzyPinyin.presets.count, 11)
  }

  /// The app writes the composed algebra as a list patch; this is the shape it lands in.
  func testComposedAlgebraWritesAsAListPatch() throws {
    let base = try engine.withSchemaConfig("tracer") { $0.value("speller/algebra") }?.listValue ?? []
    let composed = RimeFuzzyPinyin.compose(baseAlgebra: base.compactMap(\.stringValue),
                                           enabled: ["zh_z", "sh_s"])
    XCTAssertFalse(composed.isEmpty)

    let schemaPatch = RimePatch(engine: engine, configID: "tracer")
    try schemaPatch.set(.list(composed.map { .string($0) }), at: "speller/algebra")
    try redeploy()

    let deployed = try engine.withSchemaConfig("tracer") { $0.value("speller/algebra") }?.listValue ?? []
    let deployedRules = deployed.compactMap(\.stringValue)
    XCTAssertTrue(deployedRules.contains("derive/^zh/z/"), deployedRules.joined(separator: " "))
    XCTAssertTrue(deployedRules.contains("derive/^sh/s/"))
    // The schema's own rules are still there, and no generated rule appears twice.
    XCTAssertEqual(deployedRules.filter { $0 == "derive/^zh/z/" }.count, 1)
    XCTAssertEqual(RimeFuzzyPinyin.enabledPresets(in: deployedRules).sorted(), ["sh_s", "zh_z"])
  }

  /// An imported tree, or a user with an editor, can hand Arkey a patch written as **nested maps** — the
  /// form Rime applies by replacing the map it names. Arkey normalises it on the next write: the file is
  /// read as leaves (librime's reader sees them) and written back flat, so
  /// `translator: {enable_completion: true}` stops deleting `translator/dictionary` on the way in.
  func testANestedPatchFromOutsideIsNormalisedAndKeepsItsMapsSiblings() throws {
    let schemaPatch = RimePatch(engine: engine, configID: "tracer")
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: engine.directories.userDataDir), withIntermediateDirectories: true)
    try """
    # hand-written, the way an imported tree carries it
    patch:
      translator:
        enable_completion: true
    """.write(to: schemaPatch.patchFileURL, atomically: true, encoding: .utf8)

    XCTAssertEqual(try schemaPatch.userKeys(), ["translator/enable_completion"],
                   "the leaves are visible before anything is written")
    XCTAssertEqual(try schemaPatch.userValue("translator/enable_completion")?.boolValue, true)

    try schemaPatch.set(.int(7), at: "menu/page_size")
    let text = try String(contentsOf: schemaPatch.patchFileURL, encoding: .utf8)
    XCTAssertTrue(text.contains("\n  translator/enable_completion: true\n"), text)
    XCTAssertTrue(text.contains("\n  menu/page_size: 7\n"), text)

    try redeploy()
    let deployed = try String(contentsOf: workspace.profile(profileID).build
                              .appendingPathComponent("tracer.schema.yaml"), encoding: .utf8)
    let translator = deployed.components(separatedBy: "translator:").last ?? ""
    XCTAssertTrue(translator.contains("dictionary: tracer"), "the map it names keeps its siblings")
    XCTAssertTrue(translator.contains("enable_completion: true"), "and the change still lands")
  }
}
