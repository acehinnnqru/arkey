import XCTest
@testable import RimeEngine

/// S5-AC5's second half: adding an entry and forgiving one, through the only write path librime
/// gives us — export, change, import.
final class S5DictionaryEditTests: XCTestCase {
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
      .appendingPathComponent("arkey-s5-edit", isDirectory: true)
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
    let schema = try String(contentsOf: source.appendingPathComponent("tracer.schema.yaml"), encoding: .utf8)
    try schema.replacingOccurrences(of: "enable_user_dict: false", with: "enable_user_dict: true")
      .write(to: source.appendingPathComponent("tracer.schema.yaml"), atomically: true, encoding: .utf8)

    let directories = RimeDirectories(sharedDataDir: tracerData.path,
                                      prebuiltDataDir: tracerData.appendingPathComponent("build").path,
                                      userDataDir: workspace.userData.path,
                                      stagingDir: workspace.staging.path,
                                      logDir: workspace.log.path)
    engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.start()
    let id = try RimeImporter(workspace: workspace, engine: engine)
      .import(payload: source,
              options: RimeImportOptions(displayName: "Tracer",
                                         origin: RimeProfileSource(kind: .files))).profileID
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: id)
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    try? FileManager.default.removeItem(at: scratch)
  }

  private var editor: RimeDictionaryEditor {
    RimeDictionaryEditor(workspace: workspace, engine: engine)
  }

  private func exportedEntries() throws -> [RimeUserDictionaryExport.Entry] {
    let url = scratch.appendingPathComponent("export.txt")
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    _ = try access.perform { try engine.exportUserDictionary("tracer", to: url) }
    let text = try String(contentsOf: url, encoding: .utf8)
    return try XCTUnwrap(RimeUserDictionaryExport.parse(text: text)).entries
  }

  private func learnOneWord() throws {
    try engine.openSession()
    _ = try engine.processKeys("shurufa")
    _ = try engine.selectCandidate(at: 0)
    engine.closeSession()
  }

  func testAddingAnEntryPutsItInTheDictionary() throws {
    try learnOneWord()
    let count = try editor.add("tracer", text: "哈哈", code: "haha", weight: 3)
    XCTAssertGreaterThan(count, 1, "the learned entry is still there and the new one is too")
    let entries = try exportedEntries()
    XCTAssertTrue(entries.contains { $0.text == "哈哈" && $0.code == "haha" && $0.weight == 3 },
                  entries.map(\.text).joined(separator: ","))
  }

  func testAddingTheSameEntryTwiceReplacesItsWeightRatherThanDuplicating() throws {
    try learnOneWord()
    _ = try editor.add("tracer", text: "哈哈", code: "haha", weight: 1)
    _ = try editor.add("tracer", text: "哈哈", code: "haha", weight: 9)
    let matches = try exportedEntries().filter { $0.text == "哈哈" }
    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches.first?.weight, 9)
  }

  /// Measured, and it is why a per-word "forget" is not in the dictionary screen: **the levers import
  /// is additive.** Dropping an entry from the export and importing the shorter list back leaves the
  /// entry in the dictionary.
  func testTheLeversImportIsAdditiveSoAWordCannotBeForgottenByReimporting() throws {
    try learnOneWord()
    XCTAssertTrue(try exportedEntries().contains { $0.text == "输入法" })

    let before = try exportedEntries().count
    let after = try editor.edit("tracer") { entries in
      entries.removeAll { $0.text == "输入法" }
    }
    XCTAssertEqual(after, before - 1, "the file we wrote is one entry shorter")
    XCTAssertTrue(try exportedEntries().contains { $0.text == "输入法" },
                  "and the dictionary still has the word: import adds and updates, it does not remove")
  }

  /// Removing the whole dictionary is the deletion the API does leave us.
  func testRemovingTheWholeDictionary() throws {
    try learnOneWord()
    let database = workspace.userData.appendingPathComponent("tracer.userdb", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))

    XCTAssertTrue(try editor.removeDictionary("tracer"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    XCTAssertFalse(try editor.removeDictionary("tracer"), "a second call has nothing to remove")
  }

  func testTheEditorRefusesWhileTheKeyboardHoldsTheDictionaries() throws {
    try learnOneWord()
    let store = RimeLeaseStore(workspace: workspace, liveness: { _ in true })
    try store.claim(pid: 999_998)
    let guarded = RimeDictionaryEditor(workspace: workspace, engine: engine, leaseStore: store)
    XCTAssertThrowsError(try guarded.add("tracer", text: "哈哈", code: "haha")) { error in
      guard case RimeSyncError.refused = error else {
        return XCTFail("expected a refusal, got \(error)")
      }
    }
  }

  /// A dictionary nothing has been committed to has no database, and the editor says so rather than
  /// failing with something the user cannot act on.
  func testAddingToADictionaryWithNoDatabaseIsANamedError() throws {
    XCTAssertThrowsError(try editor.add("tracer", text: "哈哈", code: "haha")) { error in
      guard case RimeUserDictionaryError.noUserDictionary(let name) = error else {
        return XCTFail("expected noUserDictionary, got \(error)")
      }
      XCTAssertEqual(name, "tracer")
    }
  }

  func testTheExportFormatRoundTripsThroughItsOwnWriter() throws {
    let entries = [RimeUserDictionaryExport.Entry(text: "你好", code: "ni hao", weight: 7),
                   RimeUserDictionaryExport.Entry(text: "输入法", code: "shu ru fa", weight: 2)]
    let export = RimeUserDictionaryExport(entries: entries)
    let text = export.serialize()
    XCTAssertTrue(text.hasPrefix(RimeUserDictionaryExport.header))
    XCTAssertEqual(RimeUserDictionaryExport.parse(text: text)?.entries, entries)
  }

  /// S5-AC6: the schema decides whether learning — and therefore sync — has anything to do. The tracer ships
  /// with learning off, which is the state the screen has to explain; patching it on is the state that makes
  /// sync useful; and a schema that never mentions the key inherits, which is a different answer from "on".
  func testLearningIsReadFromTheSchemaRatherThanAssumed() throws {
    // This fixture rewrites the tracer so that it *does* learn: that is its whole point (S5-AC5 edits need a
    // dictionary). The screen's case — learning off, so sync has nothing to do — is the patch below.
    XCTAssertEqual(try RimeUserDictionaryLearning.isEnabled(engine: engine, schemaID: "tracer"), true)

    try RimePatch(engine: engine, configID: "tracer")
      .set(.bool(false), at: RimeUserDictionaryLearning.schemaKey)
    let id = try XCTUnwrap(try workspace.loadActiveProfile()?.profileID)
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: id)
    XCTAssertEqual(try RimeUserDictionaryLearning.isEnabled(engine: engine, schemaID: "tracer"), false,
                   "turning it off is the state S5-AC6 explains instead of erroring")

    XCTAssertNil(try RimeUserDictionaryLearning.isEnabled(engine: engine, schemaID: "not-a-schema"),
                 "a schema that says nothing inherits, and that is not the same as on")
  }
}
