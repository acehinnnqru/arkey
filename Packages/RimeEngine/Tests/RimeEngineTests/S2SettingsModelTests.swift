import XCTest
@testable import RimeEngine

/// S2 §2's second rule and S2-AC3: the model offers only the knobs the schema's translator reads,
/// and it reads the effective value and the user's override as two different things.
final class S2SettingsModelTests: XCTestCase {
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
      .appendingPathComponent("arkey-s2-model", isDirectory: true)
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
    profileID = try RimeImporter(workspace: workspace, engine: engine)
      .import(payload: source,
              options: RimeImportOptions(displayName: "Tracer", origin: RimeProfileSource(kind: .files))).profileID
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: profileID)
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    try? FileManager.default.removeItem(at: scratch)
  }

  private func redeploy() throws {
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: profileID)
    engine.closeSession()
  }

  /// Rewrites the schema's translator, which is what decides which knobs exist at all.
  private func useTableTranslator() throws {
    let schema = workspace.profile(profileID).source.appendingPathComponent("tracer.schema.yaml")
    let text = try String(contentsOf: schema, encoding: .utf8)
    let swapped = text.replacingOccurrences(of: "- script_translator", with: "- table_translator")
    XCTAssertNotEqual(swapped, text)
    try swapped.write(to: schema, atomically: true, encoding: .utf8)
    try redeploy()
  }

  // MARK: Which knobs exist

  func testAScriptTranslatorSchemaOffersCompletionAndNotSentence() throws {
    try engine.openSession()
    let descriptor = try RimeSettingsModel.describeSchema("tracer", engine: engine)

    XCTAssertEqual(descriptor.translatorKind, .script)
    XCTAssertEqual(descriptor.translatorNames, ["script_translator"])
    XCTAssertEqual(descriptor.dictionary, "tracer")
    XCTAssertFalse(descriptor.hasUserDictionary, "the tracer ships with learning off")

    let ids = descriptor.settings.map(\.id)
    XCTAssertTrue(ids.contains("completion"))
    XCTAssertTrue(ids.contains("wordCompletion"))
    XCTAssertTrue(ids.contains("maxSentences"))
    XCTAssertTrue(ids.contains("sentenceCutoff"))
    XCTAssertFalse(ids.contains("sentence"),
                   "enable_sentence belongs to a table translator; a pinyin schema would ignore it")
    XCTAssertFalse(ids.contains("encoder"))

    // The completed switch is on by default in librime, which is why the screen exists at all.
    XCTAssertEqual(descriptor.setting("completion")?.effective, .boolean(false),
                   "the tracer schema turns it off explicitly; the schema's value is what shows")
    XCTAssertFalse(try XCTUnwrap(descriptor.setting("completion")).isUserSet,
                   "inherited, not the user's choice")
  }

  func testATableTranslatorSchemaOffersTheOppositeKnobs() throws {
    try useTableTranslator()
    try engine.openSession()
    let descriptor = try RimeSettingsModel.describeSchema("tracer", engine: engine)

    XCTAssertEqual(descriptor.translatorKind, .table)
    let ids = descriptor.settings.map(\.id)
    XCTAssertTrue(ids.contains("sentence"))
    XCTAssertTrue(ids.contains("encoder"))
    XCTAssertFalse(ids.contains("completion"))
    XCTAssertFalse(ids.contains("maxSentences"))
    XCTAssertEqual(descriptor.setting("sentence")?.note,
                   "码表翻译器的开关；拼音方案不读它")
  }

  // MARK: Switches

  func testSwitchesComeFromTheSchemaAndTheirLabelsFromTheEngine() throws {
    try engine.openSession()
    let descriptor = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    let ascii = try XCTUnwrap(descriptor.switches.first { $0.name == "ascii_mode" })

    XCTAssertEqual(ascii.states, ["中文", "西文"], "the schema declares the words")
    XCTAssertEqual(ascii.labels, ["中文", "西文"], "and get_state_label confirms them")
    XCTAssertEqual(ascii.displayLabels, ["中文", "西文"])
    XCTAssertEqual(ascii.reset, 0)
    XCTAssertEqual(ascii.effective, false)
    XCTAssertTrue(descriptor.switches.contains { $0.name == "full_shape" })

    // Without a session there are no labels, and the schema's own words are what the UI falls back to.
    engine.closeSession()
    let offline = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    let offlineASCII = try XCTUnwrap(offline.switches.first { $0.name == "ascii_mode" })
    XCTAssertTrue(offlineASCII.labels.isEmpty)
    XCTAssertEqual(offlineASCII.displayLabels, ["中文", "西文"])
  }

  func testAPatchedSwitchResetIsReportedAsTheUsersValue() throws {
    let before = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    XCTAssertEqual(before.switches.map(\.name), ["ascii_mode", "full_shape"])

    let change = try RimeSettingsModel.setSwitchReset(1, forSwitch: "ascii_mode",
                                                      schemaID: "tracer", engine: engine)
    XCTAssertEqual(change.key, "switches")
    try redeploy()
    try engine.openSession()

    // The whole list survived: writing switches/@0/reset by index would have replaced it with one
    // nameless entry (measured — see s2-results.md).
    let descriptor = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    XCTAssertEqual(descriptor.switches.map(\.name), ["ascii_mode", "full_shape"])
    let ascii = try XCTUnwrap(descriptor.switches.first { $0.name == "ascii_mode" })
    XCTAssertEqual(ascii.states, ["中文", "西文"], "the states are still there")
    XCTAssertEqual(ascii.reset, 1, "the patch is what a fresh session starts from")
    XCTAssertEqual(ascii.effective, true, "and the session is in 西文 because of it")
    // "User set" is a list-level fact, because the patch is the whole list: the two switches in it
    // cannot be told apart from the file. The screen marks the section, not each row.
    XCTAssertTrue(ascii.isUserSet)
    XCTAssertTrue(try XCTUnwrap(descriptor.switches.first { $0.name == "full_shape" }).isUserSet)

    // The states the user never touched are still the schema's own.
    let fullShape = try XCTUnwrap(descriptor.switches.first { $0.name == "full_shape" })
    XCTAssertEqual(fullShape.reset, 0)
    XCTAssertEqual(fullShape.states, ["半角", "全角"])

    // A switch the schema does not declare is refused rather than written.
    XCTAssertThrowsError(try RimeSettingsModel.setSwitchReset(1, forSwitch: "ghost",
                                                              schemaID: "tracer", engine: engine)) { error in
      guard case RimePatchError.switchNotInSchema(let name) = error else {
        return XCTFail("expected switchNotInSchema, got \(error)")
      }
      XCTAssertEqual(name, "ghost")
    }
  }

  // MARK: The footer (S2 §6)

  /// S2 §6: "Every screen that writes shows the same two-state footer." The states and their words live
  /// in one place, so the screens cannot spell them two ways.
  func testTheFooterHasTheSpecsTwoStatesAndSaysWhenItFailed() {
    XCTAssertEqual(RimeSettingsFooterState.pending.text, "已修改，待部署")
    XCTAssertTrue(RimeSettingsFooterState.pending.isPending)
    XCTAssertEqual(RimeSettingsFooterState.applied("5 个文件，1.2 s").text, "已生效：5 个文件，1.2 s")
    XCTAssertEqual(RimeSettingsFooterState.applied("").text, "已生效")
    // The reason only: the state adds the label, so a caller cannot produce the sentence twice.
    XCTAssertEqual(RimeSettingsFooterState.failed("boom").text, "部署失败：boom")
    XCTAssertTrue(RimeSettingsFooterState.failed("x").isFailure)
    XCTAssertEqual(RimeSettingsFooterState.unchanged.text, "尚未修改")
    XCTAssertFalse(RimeSettingsFooterState.unchanged.isPending)
    XCTAssertFalse(RimeSettingsFooterState.unchanged.isFailure)
    XCTAssertFalse(RimeSettingsFooterState.applied("done").isFailure, "success is not a failure")
  }

  // MARK: Effective versus user value

  func testTheEffectiveValueAndTheUsersOverrideAreDifferentThings() throws {
    try engine.openSession()
    var descriptor = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    let inherited = try XCTUnwrap(descriptor.setting("pageSize"))
    XCTAssertEqual(inherited.effective, .integer(5), "the schema's own page size")
    XCTAssertFalse(inherited.isUserSet)
    XCTAssertNil(inherited.userValue)

    let patch = RimePatch(engine: engine, configID: "default")
    try patch.set(.int(7), at: "menu/page_size")
    try redeploy()
    try engine.openSession()

    descriptor = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    let patched = try XCTUnwrap(descriptor.setting("pageSize"))
    XCTAssertEqual(patched.effective, .integer(7))
    XCTAssertEqual(patched.userValue, .integer(7), "the screen shows both, and reset acts on this one")
    XCTAssertTrue(patched.isUserSet)
    XCTAssertEqual(patched.scope, .defaultConfig, "the page size is a default-config setting")

    // A schema-level setting, patched in the schema's own file.
    let schemaPatch = RimePatch(engine: engine, configID: "tracer")
    try schemaPatch.set(.bool(true), at: "translator/enable_completion")
    try redeploy()
    try engine.openSession()
    let descriptor2 = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    let completion = try XCTUnwrap(descriptor2.setting("completion"))
    XCTAssertEqual(completion.effective, .boolean(true))
    XCTAssertEqual(completion.userValue, .boolean(true))
    XCTAssertEqual(completion.scope, .schema("tracer"))
  }

  func testGlobalSettingsReadTheDefaultConfig() throws {
    let patch = RimePatch(engine: engine, configID: "default")
    try patch.set(.int(9), at: "menu/page_size")

    // Before a deploy, S2 §4's two sources disagree — which is the whole reason the screen shows
    // both: the deployed engine still uses 5, and the user's file already says 9.
    var settings = try RimeSettingsModel.globalSettings(engine: engine)
    var pageSize = try XCTUnwrap(settings.first { $0.id == "pageSize" })
    XCTAssertEqual(pageSize.effective, .integer(5), "the deployed value, pending the deploy")
    XCTAssertEqual(pageSize.userValue, .integer(9), "the user's choice, already written")
    XCTAssertTrue(pageSize.isUserSet)
    XCTAssertEqual(pageSize.scope, .defaultConfig)

    try redeploy()
    settings = try RimeSettingsModel.globalSettings(engine: engine)
    pageSize = try XCTUnwrap(settings.first { $0.id == "pageSize" })
    XCTAssertEqual(pageSize.effective, .integer(9), "and after the deploy the two agree")
  }

  /// The helper the keyboard's 中/英 key asks: does this schema have an 中英 state at all?
  func testTheEngineCanSayWhetherASchemaDeclaresASwitch() throws {
    try engine.openSession()
    XCTAssertTrue(engine.schemaDeclaresSwitch("ascii_mode"))
    XCTAssertTrue(engine.schemaDeclaresSwitch("full_shape"))
    XCTAssertFalse(engine.schemaDeclaresSwitch("simplified"), "the tracer declares no 简繁 switch")
    XCTAssertFalse(engine.schemaDeclaresSwitch("nonsense"))
  }

  func testTheDescriptorReportsWhatTheSchemaHas() throws {
    try engine.openSession()
    let descriptor = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    XCTAssertFalse(descriptor.hasPunctuator, "the tracer ships without one, which S4 leans on")
    XCTAssertFalse(descriptor.hasGrammar)
    XCTAssertEqual(descriptor.pageSize, 5)
    XCTAssertEqual(descriptor.name, "Tracer")
  }
}
