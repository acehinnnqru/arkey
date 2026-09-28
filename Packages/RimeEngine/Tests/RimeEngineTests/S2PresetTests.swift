import XCTest
@testable import RimeEngine

/// S2 §3's last two rows: the curated punctuation tables and the curated key bindings.
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

  // MARK: Key bindings

  func testTheBindingOptionsAreWellFormed() {
    let options = RimeKeyBindings.options
    XCTAssertFalse(options.isEmpty)
    XCTAssertEqual(Set(options.map(\.id)).count, options.count)
    for option in options {
      XCTAssertFalse(option.bindings.isEmpty, option.id)
      for binding in option.bindings {
        let identity = RimeKeyBindingOption.identity(of: binding)
        XCTAssertNotNil(identity, "\\(option.id) has a binding librime would not read: \\(binding)")
      }
    }
  }

  func testCompositionIsIdempotentAndKeepsTheSchemasOwnBindings() {
    let base: [RimeConfigValue] = [
      RimeKeyBindingOption.binding("has_menu", "space", "commit"),
      RimeKeyBindingOption.binding("paging", "comma", "Page_Up"),
    ]

    let once = RimeKeyBindings.compose(base: base, enabled: ["page_minus_equal"])
    XCTAssertEqual(once.count, 4, "two generated plus the schema's two own bindings")
    XCTAssertEqual(RimeKeyBindingOption.identity(of: once[0]), "paging|-|Page_Up")
    XCTAssertTrue(once.contains { RimeKeyBindingOption.identity(of: $0) == "has_menu|space|commit" },
                  "the schema's own bindings survive")

    let twice = RimeKeyBindings.compose(base: once, enabled: ["page_minus_equal"])
    XCTAssertEqual(RimeKeyBindingOption.identity(of: twice[0]),
                   RimeKeyBindingOption.identity(of: once[0]))
    XCTAssertEqual(twice.count, once.count, "composing twice must not accumulate")

    let disabled = RimeKeyBindings.compose(base: once, enabled: [])
    XCTAssertEqual(disabled.count, 2, "disabling removes only what the option generated")
    XCTAssertFalse(disabled.contains { RimeKeyBindingOption.identity(of: $0) == "paging|-|Page_Up" })
    XCTAssertTrue(disabled.contains { RimeKeyBindingOption.identity(of: $0) == "paging|comma|Page_Up" },
                  "and leaves the schema's own page key alone")

    XCTAssertEqual(RimeKeyBindings.compose(base: base, enabled: []), base)
  }

  func testTwoOptionsCanCoexistAndAreReportedFromTheDeployedList() {
    let composed = RimeKeyBindings.compose(base: [], enabled: ["page_minus_equal",
                                                               "select_semicolon_quote"])
    XCTAssertEqual(composed.count, 4)
    XCTAssertEqual(RimeKeyBindings.enabledOptions(in: composed).sorted(),
                   ["page_minus_equal", "select_semicolon_quote"])
    XCTAssertEqual(RimeKeyBindings.enabledOptions(in: []), [])
  }

  /// The catalogue owns what it can generate: enabling the option yields its binding exactly once
  /// even when the schema declared the same three fields, and disabling it takes that binding away.
  /// The alternative — trying to tell the schema's line from a generated one — is not idempotent.
  func testTheOptionOwnsTheBindingsItCanGenerate() {
    let base: [RimeConfigValue] = [RimeKeyBindingOption.binding("paging", "-", "Page_Up")]
    let enabled = RimeKeyBindings.compose(base: base, enabled: ["page_minus_equal"])
    let matches = enabled.filter { RimeKeyBindingOption.identity(of: $0) == "paging|-|Page_Up" }
    XCTAssertEqual(matches.count, 1, "present once, not duplicated")

    let disabled = RimeKeyBindings.compose(base: base, enabled: [])
    XCTAssertTrue(disabled.isEmpty, "and 'off' removes it")
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
