import XCTest
@testable import RimeEngine

/// The curated punctuation tables and their availability in a profile.
final class S2PresetTests: XCTestCase {
  // MARK: Punctuation

  func testThePunctuationPresetsAreCompleteAndDistinct() {
    let presets = RimePunctuation.presets
    XCTAssertEqual(presets.count, 3)
    XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
    XCTAssertTrue(presets.allSatisfy { !$0.displayName.isEmpty && !$0.note.isEmpty })
    XCTAssertEqual(presets.first?.importPreset, "default")
    XCTAssertEqual(RimePunctuation.preset(id: "symbols_v")?.requiresFile, "symbols_v.yaml")
    XCTAssertNil(RimePunctuation.preset(id: "nope"))
  }

  /// S2 §3's punctuation row, decided in the engine now: a preset is offered when the profile ships the table it
  /// names, because importing a table that is not there leaves the schema with no punctuation at all. This lived
  /// in the app, where nothing could reach it.
  func testAPresetIsOfferedOnlyWhenTheProfileShipsItsTable() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-punctuation", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    // A profile with the default table only: the enhanced one must be unavailable.
    try Data("symbols".utf8).write(to: scratch.appendingPathComponent("symbols.yaml"))
    var choices = RimePunctuation.choices(inSource: scratch)
    XCTAssertEqual(choices.count, RimePunctuation.presets.count)
    XCTAssertEqual(choices.first { $0.preset.id == "default" }?.isAvailable, true,
                   "the built-in mapping needs no file")
    XCTAssertEqual(choices.first { $0.preset.id == "symbols" }?.isAvailable, true)
    XCTAssertEqual(choices.first { $0.preset.id == "symbols_v" }?.isAvailable, false)

    // Ship the enhanced table as well and it becomes available.
    try Data("symbols_v".utf8).write(to: scratch.appendingPathComponent("symbols_v.yaml"))
    choices = RimePunctuation.choices(inSource: scratch)
    XCTAssertEqual(choices.first { $0.preset.id == "symbols_v" }?.isAvailable, true)

    // A source directory that does not exist offers only what needs nothing.
    let missing = RimePunctuation.choices(inSource: scratch.appendingPathComponent("nope"))
    XCTAssertEqual(missing.filter(\.isAvailable).map(\.preset.id), ["default"])
  }
}
