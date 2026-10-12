import XCTest
@testable import RimeEngine

final class PersonalDictionaryTests: XCTestCase {
  private func snapshot(_ name: String, rows: String) -> String {
    "# Rime user dictionary\n#@/db_name\t" + name + "\n#@/db_type\tuserdb\n#@/tick\t10\n" + rows
  }

  func testNormalizationUsesSyllablesAndNeverGuessesFromTextOrKeystrokes() {
    XCTAssertEqual(RimeMandarinCode.normalize("  NÜE  shu\tRU fa "), "nve shu ru fa")
    for code in ["shurufa", "ni3 hao3", "shu;ab", "zz", ""] {
      XCTAssertNil(RimeMandarinCode.normalize(code), code)
    }
  }

  func testRawSourcesAndUnknownCodesSurviveRoundTripWithoutBeingCombined() throws {
    var library = RimePersonalDictionary()
    let raw = snapshot("a", rows: "shu ru fa \t输入法\tc=8 d=0.123 t=10\nni3 hao3 \t你好\tc=2 d=0 t=7\n")
    try library.retain(dictionary: "a", snapshot: raw, isPlainMandarin: true)
    try library.retain(dictionary: "b", snapshot: snapshot("b", rows: "shu ru fa \t输入法\tc=5 d=0 t=8\n"), isPlainMandarin: true)
    let decoded = try RimeJSON.decode(RimePersonalDictionary.self, from: RimeJSON.encode(library))
    XCTAssertEqual(decoded.sources.first?.snapshot, raw)
    XCTAssertEqual(decoded.words.count, 1)
    XCTAssertEqual(decoded.unconvertedCount, 1)
    XCTAssertEqual(decoded.additions(to: RimeUserDictionarySnapshot(dictionary: nil, databaseType: nil,
      rimeVersion: nil, tick: nil, userID: nil, entries: [])).first?.weight, 1)
  }

  func testRepeatedCaptureDoesNotDuplicateSourcesButKeepsPreviousVersions() throws {
    var library = RimePersonalDictionary()
    let first = snapshot("a", rows: "ni hao \t你好\tc=2 d=0 t=3\n")
    let second = snapshot("a", rows: "ni hao \t你好\tc=3 d=0 t=4\n")
    try library.retain(dictionary: "a", snapshot: first, isPlainMandarin: true)
    try library.retain(dictionary: "a", snapshot: first, isPlainMandarin: true)
    try library.retain(dictionary: "a", snapshot: second, isPlainMandarin: true)
    XCTAssertEqual(library.sources.count, 2)
    XCTAssertEqual(library.latestSources.first?.snapshot, second)
  }

  func testDeletionInOneSourceBlocksStalePositiveSourcesAndTargetTombstones() throws {
    var library = RimePersonalDictionary()
    try library.retain(dictionary: "a", snapshot: snapshot("a", rows: "ni hao \t你好\tc=5 d=0 t=5\n"), isPlainMandarin: true)
    try library.retain(dictionary: "b", snapshot: snapshot("b", rows: "ni hao \t你好\tc=-1 d=0 t=6\n"), isPlainMandarin: true)
    let empty = try XCTUnwrap(RimeUserDictionarySnapshot.parse(text: snapshot("target", rows: "")))
    XCTAssertTrue(library.additions(to: empty).isEmpty)
    XCTAssertTrue(try XCTUnwrap(library.words.first).isDeleted)
    // Old versions remain exportable, but only the newest version of each source builds the index.
    try library.retain(dictionary: "b", snapshot: snapshot("b", rows: "ni hao \t你好\tc=1 d=0 t=7\n"), isPlainMandarin: true)
    let deletedTarget = try XCTUnwrap(RimeUserDictionarySnapshot.parse(text: snapshot("target", rows: "ni hao \t你好\tc=-1 d=0 t=9\n")))
    XCTAssertTrue(library.additions(to: deletedTarget).isEmpty)
  }

  func testUnsupportedDictionaryRemainsLosslessEvenWhenItsCodesLookLikePinyin() throws {
    var library = RimePersonalDictionary()
    let raw = snapshot("unknown", rows: "ni hao \t你好\tc=3 d=0 t=4\n")
    try library.retain(dictionary: "unknown", snapshot: raw, isPlainMandarin: false)
    XCTAssertTrue(library.words.isEmpty)
    XCTAssertEqual(library.unconvertedCount, 1)
    XCTAssertEqual(library.sources.first?.snapshot, raw)
    XCTAssertThrowsError(try library.retain(dictionary: "other", snapshot: raw, isPlainMandarin: true))
  }

  func testEmptyOrResetNativeSnapshotsDoNotEraseRetainedWordsOrDeletionMarkers() throws {
    var library = RimePersonalDictionary()
    try library.retain(dictionary: "a", snapshot: snapshot("a", rows: "ni hao \t你好\tc=3 d=0 t=4\nshu ru fa \t输入法\tc=-1 d=0 t=4\n"), isPlainMandarin: true)
    try library.retain(dictionary: "a", snapshot: snapshot("a", rows: ""), isPlainMandarin: true)
    XCTAssertEqual(library.words.count, 2)
    XCTAssertFalse(try XCTUnwrap(library.words.first { $0.text == "你好" }).isDeleted)
    XCTAssertTrue(try XCTUnwrap(library.words.first { $0.text == "输入法" }).isDeleted)
  }
}

/// These tests use actual librime databases, not mocks of its import/export behavior.
final class PersonalDictionaryIntegrationTests: XCTestCase {
  private var scratch: URL!
  private var workspace: RimeWorkspace!
  private var engine: RimeEngine!
  private var profileID: String!

  override func setUpWithError() throws {
    if let root = ProcessInfo.processInfo.environment["ARKEY_PERSONAL_COLD_START_ROOT"] {
      scratch = URL(fileURLWithPath: root)
      workspace = RimeWorkspace(root: scratch.appendingPathComponent("rime"))
      profileID = try XCTUnwrap(workspace.loadActiveProfile()?.profileID)
      let profile = workspace.profile(profileID)
      engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
        sharedDataDir: profile.source.path, prebuiltDataDir: profile.build.path,
        userDataDir: workspace.userData.path, stagingDir: workspace.staging.path, logDir: workspace.log.path)))
      _ = try engine.start()
      return
    }
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("arkey-personal-" + UUID().uuidString)
    workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime")).createDirectories()
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let tracer = root.appendingPathComponent("RimeData")
    let source = scratch.appendingPathComponent("profile")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracer.appendingPathComponent(file), to: source.appendingPathComponent(file))
    }
    let schemaURL = source.appendingPathComponent("tracer.schema.yaml")
    let schema = try String(contentsOf: schemaURL, encoding: .utf8)
      .replacingOccurrences(of: "enable_user_dict: false", with: "enable_user_dict: true")
    try schema.write(to: schemaURL, atomically: true, encoding: .utf8)
    _ = try workspace.seedInstallation(syncDirectory: scratch.appendingPathComponent("sync"))
    engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: tracer.path, prebuiltDataDir: tracer.appendingPathComponent("build").path,
      userDataDir: workspace.userData.path, stagingDir: workspace.staging.path, logDir: workspace.log.path)))
    _ = try engine.start()
    profileID = try RimeImporter(workspace: workspace, engine: engine).import(payload: source,
      options: RimeImportOptions(displayName: "Learning", origin: RimeProfileSource(kind: .files))).profileID
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: profileID)
    try engine.openSession()
    _ = try engine.setInput("shurufa")
    _ = try engine.selectCandidate(at: 0)
    engine.closeSession()
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    if ProcessInfo.processInfo.environment["ARKEY_PERSONAL_COLD_START_ROOT"] != nil { return }
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
  }

  private func service(fileManager: FileManager = .default) -> RimePersonalDictionaryService {
    RimePersonalDictionaryService(workspace: workspace, engine: engine, fileManager: fileManager,
                                  compatibleBaseDictionaries: ["tracer"])
  }

  private func seedAnotherSource() throws {
    var library = try service().load()
    let raw = "# Rime user dictionary\n#@/db_name\tother\n#@/db_type\tuserdb\n#@/tick\t5\nni hao \t个人测试\tc=9 d=0 t=5\n"
    try library.retain(dictionary: "other", snapshot: raw, isPlainMandarin: true)
    try service().save(library)
  }

  private func entries() throws -> [RimeUserDictionaryExport.Entry] {
    let url = scratch.appendingPathComponent("actual.txt")
    return try RimeDictionaryAccess(workspace: workspace, engine: engine).perform {
      _ = try engine.exportUserDictionary("tracer", to: url)
      return try XCTUnwrap(RimeUserDictionaryExport.parse(text: String(contentsOf: url, encoding: .utf8))).entries
    }
  }

  func testMissingWordsMigrateOnceAndExistingLearningWeightsStayUnchanged() throws {
    let before = try entries()
    try seedAnotherSource()
    let first = try service().synchronize()
    XCTAssertTrue(first.failures.isEmpty, first.failures.joined(separator: "; "))
    XCTAssertEqual(first.imported, 1)
    let after = try entries()
    XCTAssertEqual(after.first { $0.text == "输入法" }?.weight, before.first { $0.text == "输入法" }?.weight)
    XCTAssertEqual(after.first { $0.text == "个人测试" }?.weight, 1)
    let again = try service().synchronize()
    XCTAssertEqual(again.imported, 0)
    XCTAssertEqual(try entries(), after)
    try engine.openSession()
    _ = try engine.setInput("nihao")
    XCTAssertTrue(try engine.candidateList().contains { $0.text == "个人测试" })
    engine.closeSession()
  }

  func testAnUnavailableNativeBackupDirectoryReportsFailureWithoutAbortingOrChangingWords() throws {
    let before = try entries()
    try seedAnotherSource()
    // Native Backup used to throw an uncaught C++ filesystem exception through the C API here.
    // Foundation must reject this parent before the native call, as it does for an obsolete iOS path.
    let sync = scratch.appendingPathComponent("sync")
    if FileManager.default.fileExists(atPath: sync.path) { try FileManager.default.removeItem(at: sync) }
    try Data("blocked".utf8).write(to: sync)
    let outcome = try service().synchronize()
    XCTAssertFalse(outcome.failures.isEmpty)
    XCTAssertEqual(outcome.imported, 0)
    XCTAssertEqual(try entries(), before)
    let archive = scratch.appendingPathComponent("retained.zip")
    try service().export(to: archive)
    XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    try FileManager.default.removeItem(at: sync)
    XCTAssertTrue(try service().synchronize().failures.isEmpty)
  }

  func testANewEngineCapturesExistingLearnedWordsWithoutRedeploying() throws {
    if ProcessInfo.processInfo.environment["ARKEY_PERSONAL_COLD_START_ROOT"] == nil {
      engine.shutdown()
      // Finalizing an engine does not clear all process-global deployer state. A separate process
      // reproduces launching a previously deployed installation without running maintenance first.
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = ["-XCTest", "RimeEngineTests.PersonalDictionaryIntegrationTests/testANewEngineCapturesExistingLearnedWordsWithoutRedeploying",
                           Bundle(for: Self.self).bundleURL.path]
      // XCTest dumps its environment on runner errors. Never pass unrelated credentials to a child.
      let inherited = ProcessInfo.processInfo.environment
      var environment = inherited.filter { ["HOME", "TMPDIR", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "SWIFT_TESTING_ENABLED"].contains($0.key) }
      environment["ARKEY_PERSONAL_COLD_START_ROOT"] = scratch.path
      process.environment = environment
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix(#filePath + ":") {
        print(line)
      }
      XCTAssertEqual(process.terminationStatus, 0)
      return
    }
    let outcome = try service().synchronize()
    XCTAssertTrue(outcome.failures.isEmpty, outcome.failures.joined(separator: "; "))
    XCTAssertTrue(outcome.library.words.contains { $0.text == "输入法" })
    let installation = try XCTUnwrap(workspace.loadInstallation())
    XCTAssertEqual(engine.userID(), installation.installationID)
    XCTAssertEqual(engine.userDataSyncDirectory(), scratch.appendingPathComponent("sync")
      .appendingPathComponent(installation.installationID).path)
  }

  func testImportVerificationFailureRestoresTargetAndKeepsSourceExportable() throws {
    let before = try entries()
    try seedAnotherSource()
    let outcome = try service(fileManager: VerificationFileCollision()).synchronize()
    XCTAssertFalse(outcome.failures.isEmpty)
    XCTAssertEqual(try entries(), before)
    XCTAssertTrue(try service().load().words.contains { $0.text == "个人测试" })
    let zip = scratch.appendingPathComponent("retained.zip")
    try service().export(to: zip)
    XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
    XCTAssertEqual(try service().synchronize().imported, 1, "a later retry can use the retained source")
  }

  func testExportSurvivesProfileAndNativeDictionaryRemovalWithOriginalBytes() throws {
    let outcome = try service().synchronize(applyWords: false)
    let raw = try XCTUnwrap(outcome.library.latestSources.first).snapshot
    try workspace.deleteProfile(profileID)
    _ = try RimeDictionaryEditor(workspace: workspace, engine: engine).removeDictionary("tracer")
    engine.shutdown()
    let zip = scratch.appendingPathComponent("sources.zip")
    try service().export(to: zip)
    let extracted = scratch.appendingPathComponent("extracted")
    _ = try RimeZipArchive(url: zip).extract(to: extracted)
    let hash = String(RimeDigest.sha256(of: Data(raw.utf8)).dropFirst("sha256:".count))
    XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("raw/" + hash + ".userdb.txt"), encoding: .utf8), raw)
    XCTAssertTrue(try String(contentsOf: extracted.appendingPathComponent("README.txt"), encoding: .utf8).contains("not a ZIP to unzip directly"))
  }

  func testClearingPreservesSourcesAndPausesAutomaticRefillingUntilResumed() throws {
    try service().pauseBeforeClearing("tracer")
    _ = try RimeDictionaryEditor(workspace: workspace, engine: engine).removeDictionary("tracer")
    let cleared = try service().synchronize()
    XCTAssertEqual(cleared.imported, 0)
    XCTAssertTrue(cleared.library.pausedDictionaries.contains("tracer"))
    XCTAssertTrue(cleared.library.words.contains { $0.text == "输入法" })
    try service().resume("tracer")
    XCTAssertGreaterThan(try service().synchronize().imported, 0)
    XCTAssertTrue(try entries().contains { $0.text == "输入法" })
  }

  func testCorruptSourceStoreIsNeverReplacedWithAnEmptyLibrary() throws {
    _ = try service().synchronize(applyWords: false)
    let broken = Data("{broken".utf8)
    try broken.write(to: service().storeURL)
    XCTAssertThrowsError(try service().synchronize())
    XCTAssertEqual(try Data(contentsOf: service().storeURL), broken)
  }

  func testPublicationFailureRestoresOriginalDatabaseAndRetainsRetryableSources() throws {
    let before = try entries()
    try seedAnotherSource()
    let outcome = try service(fileManager: PublicationFailure()).synchronize()
    XCTAssertFalse(outcome.failures.isEmpty)
    XCTAssertEqual(try entries(), before)
    XCTAssertEqual(try service().synchronize().imported, 1)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workspace.userData.path)
      .allSatisfy { !$0.hasPrefix("arkey_personal_") })
  }

  func testInterruptedPublicationIsRecoveredBeforeLibrimeStartsOrOpensAnotherSession() throws {
    let before = try entries()
    engine.shutdown()
    let directory = workspace.userData.appendingPathComponent("arkey-personal-transactions/personal-merge-interrupted")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = RimePersonalDictionaryTransaction.Record(dictionary: "tracer", temporaryName: "arkey_personal_interrupted",
                                                          hadOriginal: true, phase: .publishing)
    try RimeJSON.encode(record).write(to: directory.appendingPathComponent("transaction.json"))
    let database = workspace.userData.appendingPathComponent("tracer.userdb")
    try FileManager.default.moveItem(at: database, to: directory.appendingPathComponent("original.userdb"))
    try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
    try Data("incomplete".utf8).write(to: database.appendingPathComponent("sentinel"))
    _ = try engine.start()
    XCTAssertEqual(try entries(), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    // The same boundary also applies when initialization survived but a publication did not.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try RimeJSON.encode(record).write(to: directory.appendingPathComponent("transaction.json"))
    try FileManager.default.moveItem(at: database, to: directory.appendingPathComponent("original.userdb"))
    try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
    try engine.openSession()
    engine.closeSession()
    XCTAssertEqual(try entries(), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testStoredSourceExportDoesNotNeedNativeDictionaryOwnership() throws {
    _ = try service().synchronize(applyWords: false)
    let ownership = try RimeLeaseStore(workspace: workspace).acquireLock()
    try withExtendedLifetime(ownership) {
      XCTAssertThrowsError(try service().synchronize())
      let url = scratch.appendingPathComponent("offline.zip")
      try service().export(to: url)
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
  }

  func testAnUnreadableSourceDefersMigrationSoHiddenDeletionsCannotBeReintroduced() throws {
    let before = try entries()
    try seedAnotherSource()
    let outcome = try service(fileManager: MissingSourceListing()).synchronize()
    XCTAssertFalse(outcome.failures.isEmpty)
    XCTAssertEqual(outcome.imported, 0)
    XCTAssertEqual(try entries(), before)
    XCTAssertTrue(try service().load().words.contains { $0.text == "个人测试" })
    XCTAssertEqual(try service().synchronize().imported, 1)
  }
}

private final class VerificationFileCollision: FileManager, @unchecked Sendable {
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                attributes: [FileAttributeKey: Any]? = nil) throws {
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    if url.lastPathComponent.hasPrefix("personal-merge-") {
      try super.createDirectory(at: url.appendingPathComponent("verified.txt"), withIntermediateDirectories: true)
    }
  }
}

private final class PublicationFailure: FileManager, @unchecked Sendable {
  override func moveItem(at source: URL, to destination: URL) throws {
    if source.lastPathComponent.hasPrefix("arkey_personal_"), destination.lastPathComponent == "tracer.userdb" {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.moveItem(at: source, to: destination)
  }
}

private final class MissingSourceListing: FileManager, @unchecked Sendable {
  override func contentsOfDirectory(atPath path: String) throws -> [String] {
    let names = try super.contentsOfDirectory(atPath: path)
    return URL(fileURLWithPath: path).lastPathComponent == "user" ? names + ["unreadable.userdb"] : names
  }
}

final class PersonalDictionaryTransactionTests: XCTestCase {
  func testRecoveryDiscardsUncommittedNewDatabaseButKeepsCommittedPublication() throws {
    let userData = FileManager.default.temporaryDirectory.appendingPathComponent("arkey-transactions-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: userData) }
    for phase in [RimePersonalDictionaryTransaction.Phase.preparing, .publishing, .committed] {
      let name = phase.rawValue
      let directory = userData.appendingPathComponent("arkey-personal-transactions/personal-merge-" + name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let record = RimePersonalDictionaryTransaction.Record(dictionary: name, temporaryName: "arkey_personal_" + name,
                                                            hadOriginal: false, phase: phase)
      try RimeJSON.encode(record).write(to: directory.appendingPathComponent("transaction.json"))
      let target = userData.appendingPathComponent(name + ".userdb")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      try Data(name.utf8).write(to: target.appendingPathComponent("contents"))
      let temporary = userData.appendingPathComponent(record.temporaryName + ".userdb")
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    let transaction = RimePersonalDictionaryTransaction(userData: userData, fileManager: .default)
    try transaction.recoverAll()
    XCTAssertTrue(FileManager.default.fileExists(atPath: userData.appendingPathComponent("preparing.userdb").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: userData.appendingPathComponent("publishing.userdb").path))
    XCTAssertEqual(try String(contentsOf: userData.appendingPathComponent("committed.userdb/contents"), encoding: .utf8), "committed")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: userData.appendingPathComponent("arkey-personal-transactions").path).isEmpty)
    XCTAssertNoThrow(try transaction.recoverAll(), "recovery is idempotent")
  }
}
