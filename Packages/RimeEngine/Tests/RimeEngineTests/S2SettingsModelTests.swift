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

  /// Two switch changes made before either is deployed are a sequence, not a race: the second reads the first
  /// out of the patch, which holds the whole list.
  ///
  /// Reading the *deployed* list instead lost the first of every rapid pair — the deployed configuration does
  /// not know about a write that has not been deployed — and the 方案 screen produces exactly that pair the
  /// moment its writes are queued rather than run on the tap (reported: 方案的开关特别卡).
  func testTwoSwitchChangesBeforeADeployBothSurvive() throws {
    try RimeSettingsModel.setSwitchReset(1, forSwitch: "ascii_mode", schemaID: "tracer", engine: engine)
    try RimeSettingsModel.setSwitchReset(1, forSwitch: "full_shape", schemaID: "tracer", engine: engine)

    // Nothing has been deployed, so the engine still says 0 for the first one as well. ("User set" is a
    // list-level fact read from the patch file, so it is already true — see the switch test above.)
    let deployed = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    XCTAssertEqual(deployed.switches.first { $0.name == "ascii_mode" }?.reset, 0)

    let patched = try XCTUnwrap(RimePatch(engine: engine, configID: "tracer")
      .userValue("switches")?.listValue)
    XCTAssertEqual(patched.count, 2, "the patch is still the schema's whole list")
    let resets = patched.compactMap { entry -> Int? in
      guard let map = entry.mapValue, let name = map["name"]?.stringValue,
            name == "ascii_mode" || name == "full_shape" else { return nil }
      return map["reset"]?.intValue
    }
    XCTAssertEqual(resets, [1, 1], "the second change replaced the first instead of joining it")
  }

  /// What the screen shows between a tap and the deploy that makes it true.
  ///
  /// A control whose value comes from the deployed configuration cannot move until the deploy ends, and a real
  /// configuration's deploy takes tens of seconds. These are the values that fill that gap; the screen lays them
  /// over the engine's answer (`RimeAppModel.refreshSettings`), so the control is never the thing that waits.
  func testADescriptorCanCarryTheChoiceMadeBeforeTheDeploy() throws {
    let before = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    XCTAssertEqual(before.switches.first { $0.name == "ascii_mode" }?.reset, 0)

    let chosen = before.replacingSwitchReset(1, forSwitch: "ascii_mode")
    let ascii = try XCTUnwrap(chosen.switches.first { $0.name == "ascii_mode" })
    XCTAssertEqual(ascii.reset, 1, "the switch moves on the tap")
    XCTAssertTrue(ascii.isUserSet, "and the section is marked as the user's, which is what the write makes true")
    XCTAssertEqual(chosen.switches.first { $0.name == "full_shape" }?.reset, 0, "the others are untouched")
    XCTAssertEqual(before.switches.first { $0.name == "ascii_mode" }?.reset, 0,
                   "the descriptor is a value: the one it came from is unchanged")

    let completion = try XCTUnwrap(before.setting("completion"))
    XCTAssertFalse(completion.isUserSet)
    let chosenSetting = before.replacingSetting(.boolean(false), forKey: "translator/enable_completion")
    XCTAssertEqual(chosenSetting.settings.count, before.settings.count)
    XCTAssertEqual(chosenSetting.setting("completion")?.effective, .boolean(false))
    XCTAssertTrue(try XCTUnwrap(chosenSetting.setting("completion")).isUserSet)
    let cleared = chosenSetting.clearingSetting("translator/enable_completion")
    XCTAssertFalse(try XCTUnwrap(cleared.setting("completion")).isUserSet)
    XCTAssertEqual(cleared.setting("completion")?.effective, .boolean(false))

    // A key the schema does not declare leaves the descriptor alone rather than inventing a row for it.
    XCTAssertEqual(before.replacingSetting(.integer(9), forKey: "ghost/key").settings.count,
                   before.settings.count)
    XCTAssertEqual(before.replacingSwitchReset(1, forSwitch: "ghost").switches.count,
                   before.switches.count)
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

  func testOmittedSettingsKeepTheirTypesAndCanBeSetAndReset() throws {
    let before = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    let boolean = try XCTUnwrap(before.setting("wordCompletion"))
    let integer = try XCTUnwrap(before.setting("maxSentences"))
    XCTAssertNil(boolean.effective)
    XCTAssertNil(integer.effective)
    XCTAssertEqual(boolean.valueType, .boolean)
    XCTAssertEqual(integer.valueType, .integer)
    XCTAssertFalse(boolean.isUserSet)
    XCTAssertFalse(integer.isUserSet)

    let chosen = before.replacingSetting(.boolean(false), forKey: boolean.key)
      .replacingSetting(.integer(4), forKey: integer.key)
    XCTAssertEqual(chosen.setting("wordCompletion")?.valueType, .boolean)
    XCTAssertEqual(chosen.setting("maxSentences")?.valueType, .integer)

    let patch = RimePatch(engine: engine, configID: "tracer")
    try patch.set(.bool(false), at: boolean.key)
    try patch.set(.int(4), at: integer.key)
    try redeploy()
    let saved = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    XCTAssertEqual(saved.setting("wordCompletion")?.effective, .boolean(false))
    XCTAssertEqual(saved.setting("maxSentences")?.effective, .integer(4))
    XCTAssertTrue(try XCTUnwrap(saved.setting("wordCompletion")).isUserSet)
    XCTAssertTrue(try XCTUnwrap(saved.setting("maxSentences")).isUserSet)

    try patch.remove(key: boolean.key)
    try patch.remove(key: integer.key)
    try redeploy()
    let reset = try RimeSettingsModel.describeSchema("tracer", engine: engine)
    XCTAssertNil(reset.setting("wordCompletion")?.effective)
    XCTAssertNil(reset.setting("maxSentences")?.effective)
    XCTAssertEqual(reset.setting("wordCompletion")?.valueType, .boolean)
    XCTAssertEqual(reset.setting("maxSentences")?.valueType, .integer)
    XCTAssertFalse(try XCTUnwrap(reset.setting("wordCompletion")).isUserSet)
    XCTAssertFalse(try XCTUnwrap(reset.setting("maxSentences")).isUserSet)
  }

  func testTheEffectiveValueAndTheUsersOverrideAreDifferentThings() throws {
    try engine.openSession()
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
    XCTAssertTrue(try RimeSettingsModel.globalSettings(engine: engine).isEmpty)
    XCTAssertNil(try RimeSettingsModel.describeSchema("tracer", engine: engine).setting("pageSize"))
    try redeploy()
    XCTAssertTrue(try RimeSettingsModel.globalSettings(engine: engine).isEmpty)
    XCTAssertNil(try RimeSettingsModel.describeSchema("tracer", engine: engine).setting("pageSize"))
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
