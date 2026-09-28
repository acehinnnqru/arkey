import XCTest
@testable import RimeEngine

/// S4 §11's engine-level table: every row of the commit table, the raw-input rule, paging, and the
/// literal fallback, all against a deployed fixture.
final class S4InputTests: XCTestCase {
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
      .appendingPathComponent("arkey-s4", isDirectory: true)
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
    // The fixture is the tracer schema exactly as it ships — deliberately without a punctuator.
    // That is the case S4 keeps pointing at, and the row it exercises is the fallback.

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

  private func makeDriver() throws -> RimeInputDriver {
    try engine.openSession()
    return RimeInputDriver(engine: engine)
  }

  private func type(_ text: String, into driver: RimeInputDriver) throws -> RimeInputOutcome {
    var last = try driver.refresh()
    for character in text {
      guard let code = character.asciiValue else { continue }
      last = try driver.handle(.character(UInt16(code)))
    }
    return last
  }

  // MARK: Composition

  func testMarkedTextIsTheRawInputAndCarriesNoSpaces() throws {
    let driver = try makeDriver()
    let outcome = try type("nihao", into: driver)
    XCTAssertEqual(outcome.effect, .composing)
    XCTAssertEqual(outcome.markedText, "nihao", "S4-AC2: exactly what was typed")
    XCTAssertEqual(outcome.page?.candidates.first?.text, "你好")
    // librime's own preedit is still the spaced form; the driver only ever shows the raw input.
    XCTAssertEqual(try engine.refresh().preedit, "ni hao")
  }

  func testTheFirstLetterAlreadyComposes() throws {
    let driver = try makeDriver()
    let outcome = try type("n", into: driver)
    XCTAssertEqual(outcome.effect, .composing)
    XCTAssertEqual(outcome.markedText, "n",
                   "S4-AC4: a key never does nothing, even when the menu is empty")
    XCTAssertEqual(outcome.page?.candidates.count, 0,
                   "the tracer schema has completion off, which is a data property, not a UI bug")
  }

  // MARK: The commit table

  func testSpaceCommitsTheCandidateAndClearsTheComposition() throws {
    let driver = try makeDriver()
    _ = try type("nihao", into: driver)
    let outcome = try driver.handle(.space)
    XCTAssertEqual(outcome.effect, .committed("你好"))
    XCTAssertEqual(outcome.insertText, "你好")
    XCTAssertNil(outcome.markedText)
    XCTAssertFalse(driver.isComposing)

    // With no composition a space is a space.
    let plain = try driver.handle(.space)
    XCTAssertEqual(plain.effect, .literal(" "))
    XCTAssertEqual(plain.insertText, " ")
  }

  func testSpaceWithNoEntryCommitsTheRawInput() throws {
    let driver = try makeDriver()
    _ = try type("woaini", into: driver)
    let outcome = try driver.handle(.space)
    XCTAssertEqual(outcome.effect, .committed("woaini"),
                   "measured: an input with no entry comes back as the raw letters")
  }

  func testReturnCommitsThenLetsTheClientInsertTheNewline() throws {
    let driver = try makeDriver()
    _ = try type("nihao", into: driver)
    let outcome = try driver.handle(.returnKey)
    XCTAssertEqual(outcome.effect, .commitThenNewline("你好"))
    XCTAssertEqual(outcome.insertText, "你好")
    XCTAssertNil(outcome.markedText)
    XCTAssertFalse(driver.isComposing)

    // Idle: the driver contributes nothing, and the newline is the client's business.
    let idle = try driver.handle(.returnKey)
    XCTAssertEqual(idle.effect, .none)
    XCTAssertNil(idle.insertText)
  }

  func testTappingACandidateCommitsWhatLibrimeCommits() throws {
    let driver = try makeDriver()
    _ = try type("nihao", into: driver)
    let outcome = try driver.handle(.selectCandidate(0))
    XCTAssertEqual(outcome.effect, .committed("你好"))
    XCTAssertNil(outcome.markedText)

    // "ni" has exactly one candidate in the tracer dictionary; the second candidate belongs to
    // the longer input, which is what makes an index worth testing at all.
    let fresh = try type("ni", into: driver)
    XCTAssertEqual(fresh.page?.candidates.map(\.text), ["你"])
    XCTAssertEqual(try driver.handle(.selectCandidate(0)).effect, .committed("你"))

    // Measured, and it corrects S4 §4.1's "a prefix commit leaves the rest composing": for
    // "nihao" the second candidate (你) is accepted by librime — handled is true — but produces
    // *no* commit and leaves the input exactly as it was, through select_candidate and
    // select_candidate_on_current_page alike. The UI must therefore drive itself from what came
    // back rather than from what a tap was expected to do: no commit means the composition and the
    // bar stay exactly as they are.
    _ = try type("nihao", into: driver)
    XCTAssertEqual(try engine.refresh().page?.candidates.map(\.text), ["你好", "你"])
    let second = try driver.handle(.selectCandidate(1))
    XCTAssertNil(second.insertText)
    XCTAssertEqual(second.effect, .composing)
    XCTAssertEqual(second.markedText, "nihao", "the input is untouched")
    XCTAssertTrue(driver.isComposing)

    // The candidate librime does commit ends the composition.
    let full = try driver.handle(.selectCandidate(0))
    XCTAssertEqual(full.effect, .committed("你好"))
    XCTAssertNil(full.markedText)
  }

  /// S4 §8's punctuation row, measured on the tracer fixture.
  ///
  /// The tracer ships no punctuator, which is the case that cost it a device run: "." is declined
  /// and must be typed literally rather than doing nothing (S4-AC4).
  ///
  /// The other half of the row — "the schema's punctuator commits it" — is **not** verifiable
  /// against this data. A punctuator processor configured both inline (`punctuator/half_shape`)
  /// and through a real `symbols.yaml` preset, in both processor orders, still did not punctuate on
  /// the pinned build; the key joined the raw input instead. That is recorded in s4-results.md and
  /// needs a published config (rime-ice) to check, so it is not asserted here.
  func testDeclinedPunctuationIsTypedLiterally() throws {
    let driver = try makeDriver()
    let declined = try driver.handle(.character(UInt16(UnicodeScalar(".").value)))
    XCTAssertEqual(declined.effect, .literal("."),
                   "a refused key with no composition types the character")
    XCTAssertEqual(declined.insertText, ".")
    XCTAssertNil(declined.markedText, "and leaves no composition behind")

    // Measured: mid-composition the same key behaves differently — Rime's editor ends the
    // composition and the character itself is not inserted. That is the behaviour a punctuator
    // would override in a config that has one, and it is what a user sees as 标点断句.
    _ = try type("nihao", into: driver)
    let composing = try driver.handle(.character(UInt16(UnicodeScalar(".").value)))
    XCTAssertEqual(composing.effect, .committed("你好"))
    XCTAssertNil(composing.markedText)
  }

  func testEscapeClearsTheComposition() throws {
    let driver = try makeDriver()
    _ = try type("nihao", into: driver)
    XCTAssertTrue(driver.isComposing)
    let outcome = try driver.handle(.escape)
    XCTAssertEqual(outcome.effect, .cleared)
    XCTAssertNil(outcome.markedText)
    XCTAssertFalse(driver.isComposing)
    XCTAssertEqual(outcome.page?.candidates.count, 0)
  }

  func testBackspaceEditsTheCompositionAndThenDeletesInTheClient() throws {
    let driver = try makeDriver()
    _ = try type("nihao", into: driver)
    let edited = try driver.handle(.backspace)
    XCTAssertEqual(edited.effect, .composing)
    XCTAssertEqual(edited.markedText, "niha")
    XCTAssertFalse(edited.deleteBackward)

    // Back to the start of the composition.
    for _ in 0..<4 { _ = try driver.handle(.backspace) }
    XCTAssertFalse(driver.isComposing)
    let atStart = try driver.handle(.backspace)
    XCTAssertTrue(atStart.deleteBackward,
                  "measured: librime declines the key with nothing composing, so the client deletes")
    XCTAssertNil(atStart.insertText)
  }

  // MARK: Paging

  func testPagingChangesThePageAndNeverCommits() throws {
    // Force a one-candidate page so the fixture has more than one page.
    let patch = RimePatch(engine: engine, configID: "default")
    try patch.set(.int(1), at: "menu/page_size")
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: profileID)
    engine.closeSession()

    let driver = try makeDriver()
    _ = try type("nihao", into: driver)
    let first = try driver.refresh()
    XCTAssertEqual(first.page?.pageNumber, 0)
    XCTAssertEqual(first.page?.candidates.count, 1)
    XCTAssertEqual(first.page?.isLastPage, false)
    XCTAssertNil(first.insertText)

    let second = try driver.handle(.pageForward)
    XCTAssertEqual(second.effect, .paged)
    XCTAssertEqual(second.page?.pageNumber, 1)
    XCTAssertNil(second.insertText, "paging never commits")
    XCTAssertTrue(driver.isComposing, "and the composition is untouched")

    let back = try driver.handle(.pageBackward)
    XCTAssertEqual(back.page?.pageNumber, 0)
  }

  // MARK: Options

  func testTogglingAnOptionIsVisibleInTheStatusAndKeepsTyping() throws {
    let driver = try makeDriver()
    let initial = try driver.handle(.toggleOption("ascii_mode"))
    XCTAssertEqual(initial.status?.isAsciiMode, true)
    XCTAssertEqual(try engine.stateLabel(option: "ascii_mode", state: true), "西文")

    let back = try driver.handle(.toggleOption("ascii_mode"))
    XCTAssertEqual(back.status?.isAsciiMode, false)
    XCTAssertEqual(try engine.stateLabel(option: "ascii_mode", state: false), "中文")

    // The composition survives a mode flip, which is what makes 中/英 a toggle and not a reset.
    _ = try type("nihao", into: driver)
    let flipped = try driver.handle(.toggleOption("full_shape"))
    XCTAssertEqual(flipped.status?.isFullShape, true)
    XCTAssertEqual(flipped.markedText, "nihao")
  }

  /// The literal fallback must not invent text for keys that are not printable.
  func testNonPrintableCodesHaveNoLiteral() {
    XCTAssertNil(RimeInputDriver.literal(for: 0x0D))
    XCTAssertNil(RimeInputDriver.literal(for: 0x1B))
    XCTAssertEqual(RimeInputDriver.literal(for: 0x2E), ".")
    XCTAssertEqual(RimeInputDriver.literal(for: 0x7A), "z")
  }

  /// S4-AC4: the extension asks this one predicate before inserting the literal character, and it used to ask
  /// it three times as an inline expression. Each field is exercised, so a change to any of them shows up here
  /// rather than as a key that does nothing.
  func testTheLiteralFallbackIsOnePredicate() {
    func output(handled: Bool, commit: String?, preedit: String?) -> RimeOutput {
      RimeOutput(handled: handled, commit: commit,
                 composition: preedit.map { RimeCompositionInfo(preedit: $0, cursorPosition: 0,
                                                                selectionStart: 0, selectionEnd: 0) },
                 page: nil, status: nil)
    }

    XCTAssertTrue(output(handled: false, commit: nil, preedit: nil).needsLiteralFallback,
                  "declined and nothing composing: the keyboard must type the character")
    XCTAssertFalse(output(handled: true, commit: nil, preedit: nil).needsLiteralFallback,
                   "librime took it")
    XCTAssertFalse(output(handled: false, commit: "你", preedit: nil).needsLiteralFallback,
                   "it committed something instead")
    XCTAssertFalse(output(handled: false, commit: nil, preedit: "n").needsLiteralFallback,
                   "a composition is in progress — the text is not the client's yet")
  }
}
