import XCTest
@testable import RimeEngine

/// S1 §10's import, classification, validation and deploy items — the whole pipeline, on macOS.
final class S1ImportTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL {
    repositoryRoot.appendingPathComponent("RimeData", isDirectory: true)
  }

  private var scratch: URL!
  private var workspace: RimeWorkspace!
  private var engine: RimeEngine!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s1-import", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()
    let directories = RimeDirectories(sharedDataDir: tracerData.path,
                                      prebuiltDataDir: tracerData.appendingPathComponent("build").path,
                                      userDataDir: workspace.userData.path,
                                      stagingDir: workspace.staging.path,
                                      logDir: workspace.log.path)
    engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.start()
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    try? FileManager.default.removeItem(at: scratch)
  }

  // MARK: Fixtures

  /// A minimal but complete config: default.yaml, one schema, its dictionary.
  @discardableResult
  private func makeConfigTree(name: String = "config", withDefaultYAML: Bool = true,
                              directory: URL? = nil) throws -> URL {
    let root = (directory ?? scratch).appendingPathComponent(name, isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] where
      !(file == "default.yaml" && !withDefaultYAML) {
      try fileManager.copyItem(at: tracerData.appendingPathComponent(file),
                               to: root.appendingPathComponent(file))
    }
    return root
  }

  private func importer() -> RimeImporter {
    RimeImporter(workspace: workspace, engine: engine)
  }

  private func options(name: String = "Tracer") -> RimeImportOptions {
    RimeImportOptions(displayName: name,
                      tag: "nightly",
                      origin: RimeProfileSource(kind: .files),
                      license: RimeProfileLicense(spdx: "MIT", name: "MIT License"))
  }

  private func stagingEntryCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: workspace.staging.path).count) ?? 0
  }

  // MARK: Happy path

  func testImportingAFolderInstallsADeployableProfile() throws {
    let tree = try makeConfigTree()
    let outcome = try importer().import(payload: tree, options: options())

    XCTAssertEqual(outcome.metadata.displayName, "Tracer")
    XCTAssertEqual(outcome.metadata.stats.schemaIDs, ["tracer"])
    XCTAssertEqual(outcome.metadata.license?.spdx, "MIT")
    XCTAssertEqual(outcome.metadata.deploy?.generation, nil, "an import is not a deploy")
    XCTAssertTrue(outcome.sourceDigest.hasPrefix("sha256:"))
    XCTAssertTrue(outcome.warnings.isEmpty, outcome.warnings.map(\.description).joined(separator: "; "))
    XCTAssertEqual(stagingEntryCount(), 0, "staging is emptied on every exit")

    let layout = workspace.profile(outcome.profileID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.source.appendingPathComponent("tracer.schema.yaml").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.build.path), "the importer does not deploy")

    let listed = try workspace.loadMetadataList()
    XCTAssertEqual(listed.map(\.id), [outcome.profileID])
  }

  func testImportingAZipProducesTheSameProfileAsTheFolder() throws {
    let tree = try makeConfigTree()
    var writer = RimeZipWriter()
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      let data = try Data(contentsOf: tree.appendingPathComponent(file))
      try writer.addFile(path: file, contents: data)
    }
    let zip = scratch.appendingPathComponent("config.zip")
    try writer.write(to: zip)

    let fromZip = try importer().import(payload: zip, options: options())
    XCTAssertEqual(fromZip.metadata.stats.schemaIDs, ["tracer"])

    // The same content through the folder path shares the id: the id is content-addressed, so two
    // entry points cannot produce two copies of one config.
    let fromFolder = try importer().import(payload: tree, options: options())
    XCTAssertEqual(fromZip.profileID, fromFolder.profileID)
    XCTAssertTrue(fromFolder.replacedExisting, "the second import is an update of the same content")
  }

  func testReimportPreservesAnExistingDeploymentAndChangedContentInstallsSeparately() throws {
    let tree = try makeConfigTree()
    let first = try importer().import(payload: tree, options: options())
    let layout = workspace.profile(first.profileID)
    try FileManager.default.createDirectory(at: layout.build, withIntermediateDirectories: true)
    let table = layout.build.appendingPathComponent("tracer.table.bin")
    try Data("published build".utf8).write(to: table)
    var metadata = first.metadata
    metadata.deploy = RimeProfileDeployRecord(generation: 2, deployedAt: Date(),
      engineVersion: RimeEngineVersion.pinned, durationSeconds: 1)
    try workspace.writeMetadata(metadata)
    let again = try importer().import(payload: tree, options: options())
    XCTAssertEqual(again.profileID, first.profileID)
    XCTAssertEqual(again.metadata.deploy?.generation, 2)
    XCTAssertEqual(try Data(contentsOf: table), Data("published build".utf8))
    let dictionary = tree.appendingPathComponent("tracer.dict.yaml")
    var text = try String(contentsOf: dictionary, encoding: .utf8)
    text += "newword\tnewword\t1\n"
    try text.write(to: dictionary, atomically: true, encoding: .utf8)
    let changed = try importer().import(payload: tree, options: options())
    XCTAssertNotEqual(changed.profileID, first.profileID)
    XCTAssertNil(changed.metadata.deploy)
    XCTAssertTrue(FileManager.default.fileExists(atPath: table.path))
  }

  func testImportingATreeWithAWrappingFolderFindsTheConfigRoot() throws {
    let wrapper = scratch.appendingPathComponent("rime-ice-nightly", isDirectory: true)
    try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
    try makeConfigTree(directory: wrapper)
    try Data("readme".utf8).write(to: wrapper.appendingPathComponent("README.md"))

    let outcome = try importer().import(payload: wrapper, options: options())
    XCTAssertEqual(outcome.metadata.stats.schemaIDs, ["tracer"])
  }

  // MARK: Root location failures

  func testAmbiguousAndMissingConfigRootsAreNamedErrors() throws {
    // Two configs side by side.
    let pair = scratch.appendingPathComponent("pair", isDirectory: true)
    try FileManager.default.createDirectory(at: pair, withIntermediateDirectories: true)
    try makeConfigTree(name: "a", directory: pair)
    try makeConfigTree(name: "b", directory: pair)
    XCTAssertThrowsError(try importer().import(payload: pair, options: options())) { error in
      guard case RimeImportError.configRootAmbiguous(let names) = error else {
        return XCTFail("expected configRootAmbiguous, got \(error)")
      }
      XCTAssertEqual(names.sorted(), ["a", "b"])
    }

    // Nothing that looks like a config.
    let junk = scratch.appendingPathComponent("junk", isDirectory: true)
    try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: junk.appendingPathComponent("notes.txt"))
    XCTAssertThrowsError(try importer().import(payload: junk, options: options())) { error in
      guard case RimeImportError.configRootNotFound = error else {
        return XCTFail("expected configRootNotFound, got \(error)")
      }
    }
    XCTAssertEqual(stagingEntryCount(), 0, "a failed import leaves staging empty")
  }

  /// Round 190's archive: `zip -r backup.zip /Users/me/Library/Rime` stores the path, so a perfectly good
  /// config arrives four folders down. §5.1 stage 3's cap still refuses it — a nested archive must not be
  /// mistaken for the config — but the refusal has to say *where* the config is, because "no folder in the
  /// import holds default.yaml and a schema" is untrue of this archive and leaves the user nothing to do.
  func testAnArchiveThatStoresThePathToTheConfigSaysWhereItIs() throws {
    let rime = try makeConfigTree(name: "Rime",
                                  directory: scratch.appendingPathComponent("Users/me/Library",
                                                                            isDirectory: true))
    var writer = RimeZipWriter()
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try writer.addFile(path: "Users/me/Library/Rime/" + file,
                         contents: try Data(contentsOf: rime.appendingPathComponent(file)))
    }
    let zip = scratch.appendingPathComponent("backup.zip")
    try writer.write(to: zip)

    XCTAssertThrowsError(try importer().import(payload: zip, options: options())) { error in
      guard case RimeImportError.configRootTooDeep(let path, let depth) = error else {
        return XCTFail("expected configRootTooDeep, got \(error)")
      }
      XCTAssertEqual(path, "Users/me/Library/Rime")
      XCTAssertEqual(depth, 4)
      XCTAssertTrue(String(describing: error).contains("Pack the Rime folder itself"),
                    "the refusal has to say what to do about it: \(error)")
    }
    XCTAssertEqual(stagingEntryCount(), 0, "a refused import leaves staging empty")
  }

  func testSchemasWithoutDefaultYAMLGetAGeneratedOne() throws {
    let tree = try makeConfigTree(withDefaultYAML: false)
    let outcome = try importer().import(payload: tree, options: options())
    let generated = try XCTUnwrap(outcome.generatedDefaultYAML)
    XCTAssertTrue(generated.contains("schema_list:"), generated)
    XCTAssertTrue(generated.contains("- schema: tracer"), generated)

    let written = try String(contentsOf: workspace.profile(outcome.profileID).source
      .appendingPathComponent("default.yaml"), encoding: .utf8)
    XCTAssertTrue(written.contains("Generated by Arkey"), written)
  }

  // MARK: Classification

  func testASquirrelShapedTreeSplitsIntoProfileAndUserData() throws {
    let tree = try makeConfigTree()
    let fileManager = FileManager.default
    try Data("patch:\n  menu:\n    page_size: 7\n".utf8)
      .write(to: tree.appendingPathComponent("default.custom.yaml"))
    try Data("你好\tni hao\n".utf8).write(to: tree.appendingPathComponent("custom_phrase.txt"))
    try Data("var:\n  last_schema: tracer\n".utf8).write(to: tree.appendingPathComponent("user.yaml"))
    try Data("installation_id: MAC\nsync_dir: /Users/x/Rime/sync\n".utf8)
      .write(to: tree.appendingPathComponent("installation.yaml"))
    try fileManager.createDirectory(at: tree.appendingPathComponent("tracer.userdb", isDirectory: true),
                                    withIntermediateDirectories: true)
    try Data("leveldb".utf8).write(to: tree.appendingPathComponent("tracer.userdb/CURRENT"))
    try fileManager.createDirectory(at: tree.appendingPathComponent("sync/PHONE", isDirectory: true),
                                    withIntermediateDirectories: true)
    try Data("snapshot".utf8).write(to: tree.appendingPathComponent("sync/PHONE/tracer.userdb.txt"))
    try fileManager.createDirectory(at: tree.appendingPathComponent("build", isDirectory: true),
                                    withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: tree.appendingPathComponent("build/stale.bin"))

    let classification = RimeTreeClassifier.classify(root: tree)
    XCTAssertEqual(classification.userData.map(\.relativePath).sorted(),
                   ["custom_phrase.txt", "default.custom.yaml", "user.yaml"])
    XCTAssertEqual(classification.userData.first { $0.relativePath == "default.custom.yaml" }?.kind, .patch)
    XCTAssertTrue(classification.profilePaths.contains("tracer.schema.yaml"))
    XCTAssertFalse(classification.profilePaths.contains("installation.yaml"))
    XCTAssertFalse(classification.profilePaths.contains { $0.hasPrefix("tracer.userdb") })
    XCTAssertFalse(classification.profilePaths.contains { $0.hasPrefix("sync/") })
    XCTAssertFalse(classification.profilePaths.contains { $0.hasPrefix("build/") },
                   "a build directory is never imported: we deploy from the sources")
    XCTAssertEqual(classification.skipped.count, 4,
                   "installation.yaml, a userdb, the sync folder and a build directory are all refused")

    // And the importer honours the split: the patch is offered, not applied.
    let outcome = try importer().import(payload: tree, options: options())
    XCTAssertEqual(outcome.userDataCandidates.count, 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.userData
      .appendingPathComponent("default.custom.yaml").path),
                   "user settings are offered, never applied silently")
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.profile(outcome.profileID).source
      .appendingPathComponent("default.custom.yaml").path))
  }

  func testAUserDataOnlyTreeIsReportedAsASettingsImport() throws {
    let tree = scratch.appendingPathComponent("settings", isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try Data("patch: {}\n".utf8).write(to: tree.appendingPathComponent("default.custom.yaml"))
    XCTAssertThrowsError(try importer().import(payload: tree, options: options())) { error in
      guard case RimeImportError.configRootNotFound = error else {
        return XCTFail("a tree with no schema cannot be a config root, got \(error)")
      }
    }
  }

  func testAdoptingUserDataCopiesItIntoTheSharedUserDirectory() throws {
    let tree = try makeConfigTree()
    try Data("patch:\n  menu:\n    page_size: 7\n".utf8)
      .write(to: tree.appendingPathComponent("default.custom.yaml"))
    var adopting = options()
    adopting.adoptUserData = true
    let outcome = try importer().import(payload: tree, options: adopting)
    XCTAssertEqual(outcome.userDataCandidates.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.userData
      .appendingPathComponent("default.custom.yaml").path))
  }

  // MARK: Validation

  func testValidationNamesEveryBrokenFile() throws {
    let tree = try makeConfigTree()
    // 1. A schema in schema_list with no file.
    try """
    config_version: "1"
    schema_list:
      - schema: tracer
      - schema: missing
    """.write(to: tree.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
    var result = RimeConfigValidation.validate(source: tree, engine: engine)
    XCTAssertFalse(result.isAcceptable)
    XCTAssertTrue(result.errors.contains { $0.path == "missing.schema.yaml" }, result.summary)

    // 2. Back to one schema, but with a translator that names a dictionary that is not there.
    try FileManager.default.removeItem(at: tree.appendingPathComponent("default.yaml"))
    try FileManager.default.copyItem(at: tracerData.appendingPathComponent("default.yaml"),
                                     to: tree.appendingPathComponent("default.yaml"))
    let schema = try String(contentsOf: tree.appendingPathComponent("tracer.schema.yaml"), encoding: .utf8)
    try schema.replacingOccurrences(of: "dictionary: tracer", with: "dictionary: nowhere")
      .write(to: tree.appendingPathComponent("tracer.schema.yaml"), atomically: true, encoding: .utf8)
    result = RimeConfigValidation.validate(source: tree, engine: engine)
    XCTAssertTrue(result.errors.contains { $0.path == "nowhere.dict.yaml" }, result.summary)

    // 3. A file librime cannot read.
    try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: tree.appendingPathComponent("tracer.dict.yaml"))
    result = RimeConfigValidation.validate(source: tree, engine: engine)
    XCTAssertTrue(result.errors.contains { $0.path == "tracer.dict.yaml" }, result.summary)
  }

  /// A device screenshot from round 190: rime-ice's `schema_list` names nine schemas (rime_ice, t9 and seven
  /// double-pinyin variants) and they **share one dictionary**, so the five tables that dictionary imports
  /// were reported once per schema — forty-five identical lines on the screen where five files are missing.
  /// The dictionary is the thing that is broken, so it is checked once; each schema keeps its own checks.
  func testASharedDictionaryIsCheckedOnceNotOncePerSchema() throws {
    let tree = try makeConfigTree()
    let schema = try String(contentsOf: tree.appendingPathComponent("tracer.schema.yaml"), encoding: .utf8)
    var defaultYAML = ["config_version: \"1\"", "schema_list:"]
    for index in 0..<9 {
      try schema.write(to: tree.appendingPathComponent("variant" + String(index) + ".schema.yaml"),
                       atomically: true, encoding: .utf8)
      defaultYAML.append("  - schema: variant" + String(index))
    }
    try (defaultYAML.joined(separator: "\n") + "\n")
      .write(to: tree.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)

    // Every variant resolves `translator/dictionary` to this one file, and it imports a table that is absent.
    let dictionary = try String(contentsOf: tree.appendingPathComponent("tracer.dict.yaml"), encoding: .utf8)
    try dictionary.replacingOccurrences(of: "sort: by_weight",
                                        with: "import_tables:\n  - cn_dicts/8105\nsort: by_weight")
      .write(to: tree.appendingPathComponent("tracer.dict.yaml"), atomically: true, encoding: .utf8)

    let result = RimeConfigValidation.validate(source: tree, engine: engine)
    let reported = result.errors.filter { $0.path == "cn_dicts/8105.dict.yaml" }
    XCTAssertEqual(reported.count, 1,
                   "one missing table, reported " + String(reported.count) + " times: " + result.summary)
  }

  func testMissingOptionalDataIsAWarningThatNamesTheConsequence() throws {
    let tree = try makeConfigTree()
    let schema = try String(contentsOf: tree.appendingPathComponent("tracer.schema.yaml"), encoding: .utf8)
    let extended = schema + """

    simplifier:
      opencc_config: s2t.json
    lua_filter@*corrector
    """
    try extended.write(to: tree.appendingPathComponent("tracer.schema.yaml"), atomically: true, encoding: .utf8)

    let result = RimeConfigValidation.validate(source: tree, engine: engine)
    XCTAssertTrue(result.warnings.contains { $0.path == "opencc/s2t.json" }, result.summary)

    // And a declared lua script is an error, not a warning: the schema's behaviour depends on it.
    // The filter goes inside the existing engine block: a second "engine:" key would replace it.
    let withFilter = schema.replacingOccurrences(of: "  translators:\n    - script_translator",
                                                 with: "  translators:\n    - script_translator\n"
                                                   + "  filters:\n    - lua_filter@missing_filter")
    XCTAssertNotEqual(withFilter, schema, "the fixture no longer matches the tracer schema")
    try withFilter.write(to: tree.appendingPathComponent("tracer.schema.yaml"),
                         atomically: true, encoding: .utf8)
    let second = RimeConfigValidation.validate(source: tree, engine: engine)
    XCTAssertTrue(second.errors.contains { $0.path == "lua/missing_filter.lua" }, second.summary)
  }

  func testImportRefusesAConfigThatLibrimeWouldNotLoad() throws {
    let tree = try makeConfigTree()
    try "not: [valid".write(to: tree.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try importer().import(payload: tree, options: options())) { error in
      guard case RimeImportError.validation(let result) = error else {
        return XCTFail("expected a validation failure, got \(error)")
      }
      XCTAssertTrue(result.errors.contains { $0.path == "default.yaml" }, result.summary)
    }
    XCTAssertEqual(try workspace.profileIDs(), [], "a refused import installs nothing")
    XCTAssertEqual(stagingEntryCount(), 0)
  }

  /// An archive that passes the directory checks still has to survive the pipeline, and a hostile
  /// one leaves nothing behind.
  func testAHostileArchiveLeavesTheWorkspaceUntouched() throws {
    var writer = RimeZipWriter()
    try writer.addFile(path: "default.yaml", contents: try Data(contentsOf: tracerData.appendingPathComponent("default.yaml")))
    // The writer refuses unsafe paths itself, so the entry is injected by hand.
    var data = writer.data()
    let evil = Data("../evil.yaml".utf8)
    let patched = data.range(of: Data("default.yaml".utf8))
    XCTAssertNotNil(patched)
    data.replaceSubrange(patched!, with: evil)

    let zip = scratch.appendingPathComponent("evil.zip")
    try data.write(to: zip)
    XCTAssertThrowsError(try importer().import(payload: zip, options: options()))
    XCTAssertEqual(try workspace.profileIDs(), [])
    XCTAssertEqual(stagingEntryCount(), 0)
  }
}

private extension String {
  func write(to url: URL, atomically: Bool, encoding: String.Encoding) throws {
    try Data(self.utf8).write(to: url, options: atomically ? .atomic : [])
  }
}
