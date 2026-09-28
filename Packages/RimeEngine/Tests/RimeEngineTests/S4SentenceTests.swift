import XCTest
@testable import RimeEngine

/// S4 §5's sentence row, measured rather than assumed: a script translator is supposed to attempt
/// sentence composition within `max_sentences` without any switch being set.
final class S4SentenceTests: XCTestCase {
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
      .appendingPathComponent("arkey-s4-sentence", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()
    let source = scratch.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file),
                                       to: source.appendingPathComponent(file))
    }
    engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: tracerData.path,
      prebuiltDataDir: tracerData.appendingPathComponent("build").path,
      userDataDir: workspace.userData.path,
      stagingDir: workspace.staging.path,
      logDir: workspace.log.path)))
    _ = try engine.start()
    let id = try RimeImporter(workspace: workspace, engine: engine)
      .import(payload: source,
              options: RimeImportOptions(displayName: "Tracer", origin: RimeProfileSource(kind: .files))).profileID
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: id)
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    try? FileManager.default.removeItem(at: scratch)
  }

  /// Measured: with the tracer's *script* translator, two words typed as one string produce the
  /// sentence candidate, ranked first, with no switch set anywhere — S4 §5's claim that sentence
  /// composition is always attempted within @B@max_sentences@B@, rather than being an option a pinyin
  /// schema reads.
  func testTwoWordsComposeIntoOneSentenceCandidateRankedFirst() throws {
    try engine.openSession()
    let output = try engine.processKeys("nihaoshurufa")
    XCTAssertEqual(try engine.candidateList().map(\.text), ["你好输入法", "你好", "你"])
    XCTAssertEqual(output.candidates.first?.text, "你好输入法", "the sentence ranks first")
    XCTAssertEqual(try engine.rawInput(), "nihaoshurufa", "and the input is what was typed")
    XCTAssertEqual(output.preedit, "ni hao shu ru fa", "librime's own preedit is the spaced form")
  }

  /// S4 §9's budget row: a sentence commits in **one** insert, not character by character.
  func testASentenceCommitsInOneCommit() throws {
    try engine.openSession()
    _ = try engine.processKeys("nihaoshurufa")
    let committed = try engine.commitComposition()
    XCTAssertEqual(committed.commit, "你好输入法")
    XCTAssertFalse(committed.commit?.contains(" ") ?? true,
                   "no spaces are inserted between the words")
    XCTAssertFalse(committed.isComposing, "and the composition is gone in the same call")

    // A second call has nothing left to commit, which is what makes it one insert rather than a loop.
    XCTAssertNil(try engine.commitComposition().commit)
  }

  /// The whole sentence can also be typed by taking the first candidate, which is the path a user
  /// actually takes: space or a tap, and one commit.
  func testTheSentenceIsReachableFromTheOrdinaryCommitPath() throws {
    try engine.openSession()
    let driver = RimeInputDriver(engine: engine)
    _ = try driver.handle(.character(UInt16(UnicodeScalar("n").value)))
    for character in "ihaoshurufa" {
      _ = try driver.handle(.character(UInt16(UnicodeScalar(String(character).unicodeScalars.first!).value)))
    }
    let outcome = try driver.handle(.space)
    XCTAssertEqual(outcome.effect, .committed("你好输入法"))
    XCTAssertEqual(outcome.insertText, "你好输入法")
  }
}
