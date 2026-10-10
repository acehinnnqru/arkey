import XCTest
@testable import RimeEngine

/// S2 §3's 自定义短语 row: the file the user owns, read and written without losing what they wrote.
final class S2CustomPhraseTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s2-phrase", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  func testTheFileParsesTheWayTheDesktopWritesIt() {
    let text = """
    # 自定义短语
    你好\tni hao\t1
    输入法\tshurufa
    的\td\t5.5

    """
    let result = RimeCustomPhraseFile.parse(text)
    XCTAssertEqual(result.phrases.count, 3)
    XCTAssertEqual(result.phrases[0], .init(text: "你好", code: "ni hao", weight: 1))
    XCTAssertEqual(result.phrases[1], .init(text: "输入法", code: "shurufa", weight: nil),
                   "a missing weight stays missing rather than becoming a zero")
    XCTAssertEqual(result.phrases[2].weight ?? 0, 5.5, accuracy: 0.001)
    XCTAssertTrue(result.rejected.isEmpty)
  }

  func testLinesItCannotReadAreReportedWithTheirNumber() {
    let text = """
    你好\tni hao
    only-one-field
    \tmissing-text
    输入法\tshurufa

    """
    let result = RimeCustomPhraseFile.parse(text)
    XCTAssertEqual(result.phrases.count, 2)
    XCTAssertEqual(result.rejected.map(\.line), [2, 3], "the line numbers point at the file")
    XCTAssertEqual(result.rejected[0].text, "only-one-field")
  }

  func testRoundTripKeepsTheValuesAndTheTrailingNewline() {
    let phrases = [RimeCustomPhrase(text: "你好", code: "ni hao", weight: 1),
                   RimeCustomPhrase(text: "输入法", code: "shurufa")]
    let text = RimeCustomPhraseFile.serialize(phrases)
    XCTAssertTrue(text.hasSuffix("\n"), "one line per phrase, with a final newline")
    XCTAssertEqual(RimeCustomPhraseFile.parse(text).phrases, phrases)
    XCTAssertEqual(RimeCustomPhraseFile.serialize([]), "")
  }

  func testSaveAndLoadGoThroughTheUserDirectory() throws {
    let url = scratch.appendingPathComponent("user/custom_phrase.txt")
    XCTAssertEqual(try RimeCustomPhraseFile.load(from: url).phrases, [],
                   "a missing file is an empty list, not an error")
    try RimeCustomPhraseFile.save([RimeCustomPhrase(text: "你好", code: "ni hao")], to: url)
    XCTAssertEqual(try RimeCustomPhraseFile.load(from: url).phrases.count, 1)
  }

  func testTheThreeMergeStrategies() {
    let existing = [RimeCustomPhrase(text: "你好", code: "ni hao")]
    let incoming = [RimeCustomPhrase(text: "你好", code: "ni hao"),
                    RimeCustomPhrase(text: "输入法", code: "shurufa")]

    XCTAssertEqual(RimeCustomPhraseFile.merge(incoming, into: existing, strategy: .replaceAll),
                   incoming)
    XCTAssertEqual(RimeCustomPhraseFile.merge(incoming, into: existing, strategy: .keepExisting),
                   existing)
    let appended = RimeCustomPhraseFile.merge(incoming, into: existing, strategy: .appendNew)
    XCTAssertEqual(appended.count, 2, "the duplicate is not added twice")
    XCTAssertEqual(appended[0].text, "你好", "and the user's own order is kept")
    XCTAssertEqual(appended[1].text, "输入法")
  }

  /// An import through the profile library carries the phrases it found; this is the shape the screen
  /// offers to merge.
  func testAnImportedBundleCarriesPhrasesInTheFileFormat() throws {
    let url = scratch.appendingPathComponent("bundle/custom_phrase.txt")
    try RimeCustomPhraseFile.save([RimeCustomPhrase(text: "哈哈", code: "haha", weight: 2)], to: url)
    let loaded = try RimeCustomPhraseFile.load(from: url)
    XCTAssertEqual(loaded.phrases.first?.line, "哈哈\thaha\t2")
  }

  func testSharedPhrasesAppearInASchemaWithASeparateNativePhraseFile() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let tracer = repository.appendingPathComponent("RimeData")
    let workspace = try RimeWorkspace(root: scratch.appendingPathComponent("workspace")).createDirectories()
    let source = scratch.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracer.appendingPathComponent(file), to: source.appendingPathComponent(file))
    }
    let schemaURL = source.appendingPathComponent("tracer.schema.yaml")
    var schema = try String(contentsOf: schemaURL, encoding: .utf8)
    schema = schema.replacingOccurrences(of: "    - script_translator",
                                         with: "    - script_translator\n    - table_translator@custom_phrase")
    schema += """

    custom_phrase:
      dictionary: ""
      user_dict: custom_phrase_double
      db_class: stabledb
      enable_completion: false
      enable_sentence: false
      initial_quality: 99

    """
    try schema.write(to: schemaURL, atomically: true, encoding: .utf8)
    let engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: tracer.path, prebuiltDataDir: tracer.appendingPathComponent("build").path,
      userDataDir: workspace.userData.path, stagingDir: workspace.staging.path, logDir: workspace.log.path)))
    defer { engine.shutdown() }
    _ = try engine.start()
    let profileID = try RimeImporter(workspace: workspace, engine: engine).import(
      payload: source, options: RimeImportOptions(displayName: "Separate phrase file", origin: .init(kind: .files)))
      .profileID
    let nativeURL = workspace.userData.appendingPathComponent("custom_phrase_double.txt")
    try RimeCustomPhraseFile.save([.init(text: "Native phrase", code: "orig")], to: nativeURL)
    let nativeBefore = try Data(contentsOf: nativeURL)
    let sharedURL = workspace.userData.appendingPathComponent("custom_phrase.txt")
    try RimeCustomPhraseFile.save([.init(text: "我的名字", code: "mkzi")], to: sharedURL)
    let patchURL = workspace.userData.appendingPathComponent("tracer.custom.yaml")
    try """
    patch:
      "engine/translators/+":
        - echo_translator
      menu/page_size: 7

    """.write(to: patchURL, atomically: true, encoding: .utf8)
    let coordinator = RimeDeploymentCoordinator(workspace: workspace, engine: engine)
    _ = try coordinator.deploySync(profileID: profileID)
    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("mkzi").candidates.first?.text, "我的名字")
    try engine.clearComposition()
    XCTAssertEqual(try engine.processKeys("orig").candidates.first?.text, "Native phrase")
    engine.closeSession()
    _ = try coordinator.deploySync(profileID: profileID)
    let translators = try engine.withSchemaConfig("tracer") { $0.value("engine/translators")?.listValue ?? [] }
    XCTAssertEqual(translators.filter { $0 == .string("table_translator@arkey_custom_phrase") }.count, 1)
    XCTAssertTrue(translators.contains(.string("table_translator@custom_phrase")))
    XCTAssertTrue(translators.contains(.string("echo_translator")), "keep existing appended translators")
    XCTAssertEqual(try RimePatch(engine: engine, configID: "tracer").userValue("menu/page_size"), .int(7))
    XCTAssertEqual(try Data(contentsOf: nativeURL), nativeBefore)
    XCTAssertEqual(try Data(contentsOf: workspace.profile(profileID).source.appendingPathComponent("tracer.schema.yaml")),
                   try Data(contentsOf: schemaURL))
    try RimeCustomPhraseFile.save([], to: sharedURL)
    _ = try coordinator.deploySync(profileID: profileID)
    try engine.openSession()
    XCTAssertFalse(try engine.processKeys("mkzi").candidates.contains { $0.text == "我的名字" })
    try engine.clearComposition()
    XCTAssertEqual(try engine.processKeys("orig").candidates.first?.text, "Native phrase")
  }
}
