import XCTest
@testable import RimeEngine

/// S2 §7 and §8: exporting the patch set and the phrases, importing it back with a per-file merge,
/// and refusing everything that is not a setting.
final class S2SettingsTests: XCTestCase {
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
      .appendingPathComponent("arkey-s2-settings", isDirectory: true)
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

  private var portability: RimeSettingsPortability {
    RimeSettingsPortability(workspace: workspace, engine: engine)
  }

  private func writeUserFile(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: workspace.userData.appendingPathComponent(name))
  }

  // MARK: Export

  func testExportCollectsPatchesAndPhrasesAndLeavesDeviceStateBehind() throws {
    try writeUserFile("default.custom.yaml", "patch:\n  menu:\n    page_size: 7\n")
    try writeUserFile("tracer.custom.yaml", "patch:\n  translator:\n    enable_completion: true\n")
    try writeUserFile("custom_phrase.txt", "你好\tni hao\n")
    try writeUserFile("user.yaml", "var:\n  last_schema: tracer\n")
    try writeUserFile("notes.md", "not a setting")

    let bundle = try portability.export()
    XCTAssertEqual(bundle.fileNames.sorted(),
                   ["custom_phrase.txt", "default.custom.yaml", "tracer.custom.yaml"])
    XCTAssertFalse(bundle.fileNames.contains("user.yaml"),
                   "which schema was last used is device state, not a setting")
    XCTAssertEqual(bundle.manifest.engineVersion, RimeEngineVersion.pinned)
    XCTAssertEqual(bundle.manifest.schemaVersion, RimeSettingsManifest.currentSchemaVersion)
    XCTAssertTrue(bundle.manifest.files.allSatisfy { $0.sha256.hasPrefix("sha256:") })
    XCTAssertEqual(bundle.manifest.schemaIDs, ["tracer"])
  }

  func testAnExportedBundleReadsBackWithItsManifest() throws {
    try writeUserFile("default.custom.yaml", "patch:\n  menu:\n    page_size: 7\n")
    let url = scratch.appendingPathComponent("settings.zip")
    _ = try portability.export(to: url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    let inspected = try portability.inspect(url)
    XCTAssertEqual(inspected.fileNames, ["default.custom.yaml"])
    XCTAssertEqual(inspected.files.first?.text, "patch:\n  menu:\n    page_size: 7\n")
    XCTAssertEqual(inspected.manifest.schemaIDs, ["tracer"])
  }

  // MARK: Import

  func testImportReplacesFilesAndKeepsThePreviousOnesInABackup() throws {
    try writeUserFile("default.custom.yaml", "patch:\n  menu:\n    page_size: 7\n")
    let url = scratch.appendingPathComponent("settings.zip")
    _ = try portability.export(to: url)

    // The other device's copy, imported over ours.
    var writer = RimeZipWriter()
    try writer.addFile(path: "default.custom.yaml", text: "patch:\n  menu:\n    page_size: 9\n")
    let manifest = RimeSettingsManifest(schemaIDs: ["tracer"],
                                        files: [.init(path: "default.custom.yaml", bytes: 0,
                                                      sha256: "sha256:0")])
    try writer.addFile(path: "manifest.json", contents: try RimeJSON.encode(manifest))
    let incoming = scratch.appendingPathComponent("incoming.zip")
    try writer.write(to: incoming)

    let results = try portability.importSettings(from: incoming)
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.applied, true)
    XCTAssertEqual(results.first?.kind, .patch)
    XCTAssertEqual(try portability.collect().first?.text, "patch:\n  menu:\n    page_size: 9\n")

    // And the file it replaced is in the backup, so the import is reversible in one action.
    let backups = try FileManager.default.contentsOfDirectory(
      at: workspace.root.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
    XCTAssertFalse(backups.isEmpty)
    let restored = backups[0].appendingPathComponent("default.custom.yaml")
    XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8),
                   "patch:\n  menu:\n    page_size: 7\n")

    // The deployed configuration follows the imported patch after a redeploy.
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: profileID)
    XCTAssertEqual(try engine.withConfig("default") { $0.int("menu/page_size") }, 9)
  }

  func testImportCanKeepTheFileThatIsAlreadyThere() throws {
    try writeUserFile("default.custom.yaml", "patch:\n  menu:\n    page_size: 7\n")
    let url = scratch.appendingPathComponent("settings.zip")
    _ = try portability.export(to: url)

    var writer = RimeZipWriter()
    try writer.addFile(path: "default.custom.yaml", text: "patch:\n  menu:\n    page_size: 9\n")
    try writer.addFile(path: "manifest.json",
                       contents: try RimeJSON.encode(RimeSettingsManifest(schemaIDs: [])))
    let incoming = scratch.appendingPathComponent("incoming.zip")
    try writer.write(to: incoming)

    let results = try portability.importSettings(from: incoming, merge: .keepExisting)
    XCTAssertEqual(results.first?.applied, false)
    XCTAssertNotNil(results.first?.reason)
    XCTAssertEqual(try portability.collect().first?.text, "patch:\n  menu:\n    page_size: 7\n")
  }

  func testImportCanApplyASubset() throws {
    try writeUserFile("default.custom.yaml", "patch: {}\n")
    try writeUserFile("custom_phrase.txt", "你好\tni hao\n")
    let url = scratch.appendingPathComponent("settings.zip")
    _ = try portability.export(to: url)

    try FileManager.default.removeItem(at: workspace.userData.appendingPathComponent("default.custom.yaml"))
    try FileManager.default.removeItem(at: workspace.userData.appendingPathComponent("custom_phrase.txt"))

    let results = try portability.importSettings(from: url, files: ["custom_phrase.txt"])
    XCTAssertEqual(results.map(\.path), ["custom_phrase.txt"])
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: workspace.userData.appendingPathComponent("custom_phrase.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: workspace.userData.appendingPathComponent("default.custom.yaml").path))
  }

  // MARK: What is refused

  func testImportRefusesAnythingThatIsNotASetting() throws {
    var writer = RimeZipWriter()
    try writer.addFile(path: "default.yaml", text: "schema_list: []\n")
    try writer.addFile(path: "manifest.json",
                       contents: try RimeJSON.encode(RimeSettingsManifest(schemaIDs: [])))
    let url = scratch.appendingPathComponent("config.zip")
    try writer.write(to: url)

    XCTAssertThrowsError(try portability.importSettings(from: url)) { error in
      guard case RimeSettingsError.notASetting(let path) = error else {
        return XCTFail("expected notASetting, got \(error)")
      }
      XCTAssertEqual(path, "default.yaml")
    }
  }

  func testImportRefusesABundleWithNoManifest() throws {
    var writer = RimeZipWriter()
    try writer.addFile(path: "default.custom.yaml", text: "patch: {}\n")
    let url = scratch.appendingPathComponent("nomanifest.zip")
    try writer.write(to: url)
    XCTAssertThrowsError(try portability.importSettings(from: url)) { error in
      guard case RimeSettingsError.manifestMissing = error else {
        return XCTFail("expected manifestMissing, got \(error)")
      }
    }
  }

  func testImportRefusesANewerManifestAndUnsafePaths() throws {
    var newer = RimeZipWriter()
    var manifest = RimeSettingsManifest(schemaIDs: [])
    manifest.schemaVersion = 99
    try newer.addFile(path: "default.custom.yaml", text: "patch: {}\n")
    try newer.addFile(path: "manifest.json", contents: try RimeJSON.encode(manifest))
    let newerURL = scratch.appendingPathComponent("newer.zip")
    try newer.write(to: newerURL)
    XCTAssertThrowsError(try portability.importSettings(from: newerURL)) { error in
      guard case RimeSettingsError.incompatibleVersion(let version) = error else {
        return XCTFail("expected incompatibleVersion, got \(error)")
      }
      XCTAssertEqual(version, 99)
    }

    // A nested path is not a setting: this path exists to move settings, not to install a config,
    // and a zip can carry any shape it likes.
    var nested = RimeZipWriter()
    try nested.addFile(path: "sub/default.custom.yaml", text: "patch: {}\n")
    try nested.addFile(path: "manifest.json",
                       contents: try RimeJSON.encode(RimeSettingsManifest(schemaIDs: [])))
    let nestedURL = scratch.appendingPathComponent("nested.zip")
    try nested.write(to: nestedURL)
    XCTAssertThrowsError(try portability.importSettings(from: nestedURL)) { error in
      guard case RimeSettingsError.notASetting = error else {
        return XCTFail("expected notASetting, got \(error)")
      }
    }

    // A name that could escape the user directory is not a setting either. The archive reader
    // refuses such a path before the settings layer sees it (S1ArchiveTests), so this is the
    // settings layer's own half of the rule.
    XCTAssertNil(RimeSettingsFileKind.classify("../evil.custom.yaml"))
    XCTAssertNil(RimeSettingsFileKind.classify("sub/default.custom.yaml"))
    XCTAssertEqual(RimeSettingsFileKind.classify("default.custom.yaml"), .patch)
  }
}
