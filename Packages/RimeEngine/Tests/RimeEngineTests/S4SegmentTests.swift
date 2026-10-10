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

  private func engine(doublePinyin: Bool = false, expandedPreedit: Bool = false) throws -> RimeEngine {
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
    if doublePinyin {
      // Exercise the engine's spelling graph with the Flypy code used by this regression.
      // Keep the fixture local and minimal instead of depending on an imported dictionary.
      let schema = source.appendingPathComponent("tracer.schema.yaml")
      var yaml = try String(contentsOf: schema, encoding: .utf8)
        .replacingOccurrences(of: "  delimiter: \" '\"",
                              with: "  delimiter: \" '\"\n  algebra:\n    - xform/ao$/c/\n    - xform/^a$/aa/")
        .replacingOccurrences(of: "schema_id: tracer", with: "schema_id: pinyin_flypy")
      if expandedPreedit {
        yaml = yaml.replacingOccurrences(of: "  dictionary: tracer", with: """
          dictionary: tracer
          preedit_format:
            - xform/hc/hao/
            - xform/aa/a/
        """)
      }
      try yaml.write(to: source.appendingPathComponent("pinyin_flypy.schema.yaml"),
                     atomically: true, encoding: .utf8)
      try FileManager.default.removeItem(at: schema)
      let defaults = source.appendingPathComponent("default.yaml")
      try String(contentsOf: defaults, encoding: .utf8)
        .replacingOccurrences(of: "schema: tracer", with: "schema: pinyin_flypy")
        .write(to: defaults, atomically: true, encoding: .utf8)
      let dictionary = source.appendingPathComponent("tracer.dict.yaml")
      try (String(contentsOf: dictionary, encoding: .utf8) + "\n啊\ta\t100\n你好啊\tni hao a\t100\n")
        .write(to: dictionary, atomically: true, encoding: .utf8)
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
    XCTAssertEqual(output.input, "nihaoshijie", "display separators never modify the raw input")
    XCTAssertEqual(output.preedit, "ni hao shi jie", "librime divides the spelling itself")
    XCTAssertEqual(RimeKeyboardPreferences.standard.markedText(for: output), "ni hao shi jie")
    XCTAssertEqual(output.syllables, ["ni", "hao", "shi", "jie"])
  }

  func testDoublePinyinDisplaysEngineBoundariesAndReturnCommitsOriginalKeys() throws {
    let engine = try engine(doublePinyin: true)
    defer { engine.shutdown() }
    try engine.openSession()

    let output = try engine.processKeys("nihc")
    XCTAssertEqual(output.input, "nihc")
    XCTAssertEqual(output.preedit, "ni hc")
    XCTAssertEqual(RimeKeyboardPreferences.standard.markedText(for: output), "ni hc")
    XCTAssertEqual(output.candidates.first?.text, "你好")

    let committed = try engine.processKey(RimeKey.returnKey)
    XCTAssertEqual(committed.commit, "nihc")
    XCTAssertFalse(committed.isComposing)
    XCTAssertTrue((RimeKeyboardPreferences.standard.markedText(for: committed) ?? "").isEmpty)

    _ = try engine.processKeys("nihc")
    XCTAssertEqual(try engine.processKey(RimeKey.space).commit, "你好")

    _ = try engine.processKeys("nihc")
    for remaining in ["nih", "ni", "n", ""] {
      let edited = try engine.processKey(RimeKey.backSpace)
      XCTAssertEqual(edited.input, remaining)
      let displayed = RimeKeyboardPreferences.standard.markedText(for: edited) ?? ""
      XCTAssertEqual(displayed.replacingOccurrences(of: " ", with: ""), remaining)
    }
    XCTAssertFalse(try engine.refresh().isComposing)
  }

  func testExpandedFlypyPreeditKeepsRawSyllableBoundariesAcrossTypingAndDeletion() throws {
    let engine = try engine(doublePinyin: true, expandedPreedit: true)
    defer { engine.shutdown() }
    try engine.openSession()
    var preferences = RimeKeyboardPreferences.standard

    for input in ["nihc", "nihcaa"] {
      let output = try engine.processKeys(input)
      let rawDisplay = input == "nihc" ? "ni hc" : "ni hc aa"
      let expanded = input == "nihc" ? "ni hao" : "ni hao a"
      XCTAssertEqual(output.status?.schemaID, "pinyin_flypy")
      XCTAssertEqual(output.preedit, expanded)
      preferences.compositionDisplay = .rawInput
      XCTAssertEqual(preferences.markedText(for: output), rawDisplay)
      preferences.compositionDisplay = .preedit
      XCTAssertEqual(preferences.markedText(for: output), expanded)
      XCTAssertEqual(output.input, input)
      let committed = try engine.processKey(RimeKey.returnKey)
      XCTAssertEqual(committed.commit, input)
      XCTAssertFalse(committed.isComposing)
    }

    _ = try engine.processKeys("nihcaa")
    XCTAssertEqual(try engine.processKey(RimeKey.space).commit, "你好啊")
    _ = try engine.processKeys("nihcaa")
    for remaining in ["nihca", "nihc", "nih", "ni", "n", ""] {
      let output = try engine.processKey(RimeKey.backSpace)
      XCTAssertEqual(output.input, remaining)
      XCTAssertEqual((output.segmentedInput ?? "").replacingOccurrences(of: " ", with: ""), remaining)
      if remaining == "nihc" { XCTAssertEqual(output.segmentedInput, "ni hc") }
    }
    XCTAssertFalse(try engine.refresh().isComposing)
  }

  func testASingleSyllableLeavesTheRowEmpty() throws {
    let engine = try engine()
    defer { engine.shutdown() }
    try engine.openSession()

    let output = try engine.processKeys("ni")
    XCTAssertEqual(output.preedit, "ni")
    XCTAssertNil(output.syllables, "one syllable is not a division")
  }

  func testSelectingFlypyPrefixesKeepsConvertedTextAndRemainingKeysVisible() throws {
    let engine = try engine(doublePinyin: true, expandedPreedit: true)
    defer { engine.shutdown() }
    try engine.openSession()
    let initial = try engine.processKeys("nihcaa")
    let firstIndex = try XCTUnwrap(initial.candidates.firstIndex { $0.text == "你" })
    let first = try engine.selectCandidate(at: firstIndex)
    XCTAssertNil(first.commit)
    XCTAssertEqual(first.segmentedInput, "你 hc aa", String(describing: first.composition))
    XCTAssertEqual(first.input, "nihcaa")
    XCTAssertEqual(RimeKeyboardPreferences.standard.markedText(for: first), "你 hc aa")
    XCTAssertEqual(RimeKeyboardPreferences(compositionDisplay: .preedit).markedText(for: first), "你hao a")
    XCTAssertEqual(try engine.refresh().segmentedInput, "你 hc aa")
    let secondIndex = try XCTUnwrap(first.candidates.firstIndex { $0.text == "好" },
                                  first.candidates.map(\.text).joined(separator: ","))
    let second = try engine.selectCandidate(at: secondIndex)
    XCTAssertNil(second.commit)
    XCTAssertEqual(second.segmentedInput, "你好 aa", String(describing: second.composition))
    let finalIndex = try XCTUnwrap(second.candidates.firstIndex { $0.text == "啊" })
    let final = try engine.selectCandidate(at: finalIndex)
    XCTAssertEqual(final.commit, "你好啊")
    XCTAssertNil(final.segmentedInput)
  }

  func testPartialSelectionSurvivesEditingAndReturnPreservesSelectedPrefix() throws {
    let engine = try engine(doublePinyin: true, expandedPreedit: true)
    defer { engine.shutdown() }
    try engine.openSession()
    let initial = try engine.processKeys("nihc")
    let index = try XCTUnwrap(initial.candidates.firstIndex { $0.text == "你" })
    XCTAssertEqual(try engine.selectCandidate(at: index).segmentedInput, "你 hc")
    XCTAssertEqual(try engine.processKeys("aa").segmentedInput, "你 hc aa")
    // The active segment's end separates the unfinished tail even with completion disabled.
    XCTAssertEqual(try engine.processKey(RimeKey.backSpace).segmentedInput, "你 hc a")
    XCTAssertEqual(try engine.processKey(RimeKey.backSpace).segmentedInput, "你 hc")
    XCTAssertEqual(try engine.processKey(RimeKey.returnKey).commit, "你hc")

    let again = try engine.processKeys("nihcaa")
    XCTAssertEqual(again.segmentedInput, "ni hc aa")
    _ = try engine.selectCandidate(at: XCTUnwrap(again.candidates.firstIndex { $0.text == "你" }))
    try engine.clearComposition()
    XCTAssertNil(try engine.refresh().segmentedInput)
    XCTAssertEqual(try engine.processKeys("nihcaa").segmentedInput, "ni hc aa")
    engine.closeSession()
    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("nihc").segmentedInput, "ni hc")
  }

  func testDeletingSelectedPhraseRestoresRawSyllableBoundaries() throws {
    let engine = try engine(doublePinyin: true, expandedPreedit: true)
    defer { engine.shutdown() }
    try engine.openSession()
    let initial = try engine.processKeys("nihcaa")
    XCTAssertEqual(initial.segmentedInput, "ni hc aa")
    let index = try XCTUnwrap(initial.candidates.firstIndex { $0.text == "你好" })
    XCTAssertEqual(try engine.selectCandidate(at: index).segmentedInput, "你好 aa")

    let reverted = try engine.processKey(RimeKey.backSpace)
    XCTAssertNil(reverted.commit)
    XCTAssertEqual(reverted.input, "nihcaa")
    XCTAssertEqual(reverted.preedit, "ni haoaa")
    XCTAssertEqual(reverted.composition?.selectionEnd, 6)
    XCTAssertEqual(reverted.segmentedInput, "ni hc aa", String(describing: reverted.composition))
    XCTAssertEqual(RimeKeyboardPreferences.standard.markedText(for: reverted), "ni hc aa")
    XCTAssertEqual(RimeKeyboardPreferences(compositionDisplay: .preedit).markedText(for: reverted), "ni haoaa")
    XCTAssertEqual(try engine.refresh().segmentedInput, "ni hc aa")
    let deleted = try engine.processKey(RimeKey.backSpace)
    XCTAssertEqual(deleted.input, "nihca")
    XCTAssertEqual(deleted.segmentedInput, "ni hc a", String(describing: deleted.composition))
    XCTAssertEqual(try engine.processKey(RimeKey.returnKey).commit, "nihca")
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
