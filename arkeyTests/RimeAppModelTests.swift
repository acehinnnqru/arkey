import XCTest
import RimeEngine

/// The app's own first-run path, on iOS.
///
/// RimeAppModel is what the SwiftUI screens drive, and nothing had ever instantiated it: the app's sources are
/// compiled into the test bundle for these tests. It runs in the keyboard's own container workspace (the app
/// group is unavailable without entitlements), the same one the keyboard tests use, so it cleans up after
/// itself — the profile it imports and the record that points at it are removed in tearDown, which is what
/// keeps the suite repeatable.
@MainActor
final class RimeAppModelTests: XCTestCase {
  private var imported: String?
  private var scratch: URL?
  private var userFiles: [URL] = []
  private var exports: [URL] = []

  /// A busy engine must delay page data, never the main actor that animates navigation.
  func testSettingsPageReadsKeepTheMainActorResponsive() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    let engine = model.engine
    let readers: [(String, @MainActor () async -> Void)] = [
      ("schema", { await model.refreshSettings() }),
      ("keyboard", { await model.refreshPreferences() }),
      ("dictionaries", { await model.refreshDictionariesInBackground() }),
    ]
    for (name, load) in readers {
      let engineHeld = expectation(description: name + " engine held")
      let release = DispatchSemaphore(value: 0)
      let blocker = Task.detached {
        try engine.withConfig("default") { _ in
          engineHeld.fulfill()
          // A bounded wait also lets the old blocking implementation fail without deadlocking the test.
          _ = release.wait(timeout: .now() + 2)
        }
      }
      await fulfillment(of: [engineHeld], timeout: 5)
      let started = expectation(description: name + " read started")
      let begin = Date()
      let read = Task { @MainActor in
        started.fulfill()
        await load()
      }
      await fulfillment(of: [started], timeout: 5)
      // The punctuation body must also remain a memory-only read while librime is busy.
      _ = model.currentPunctuationPreset
      _ = model.punctuationChoices
      _ = model.syncDisabledReason
      _ = model.libraryEntries
      let mainActorDelay = Date().timeIntervalSince(begin)
      release.signal()
      await read.value
      try await blocker.value
      XCTAssertLessThan(mainActorDelay, 0.5, name + " blocked navigation on the engine queue")
    }
    XCTAssertFalse(model.schemaRows.isEmpty, "the background read never published the schema rows")
  }

  func testCancelledSettingsPageReadDoesNotPublishItsSnapshot() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    model.schemaRows = ["cached-row"]
    let read = Task { @MainActor in await model.refreshSettings() }
    read.cancel()
    await read.value
    XCTAssertEqual(model.schemaRows, ["cached-row"])
  }

  override func tearDownWithError() throws {
    let model = RimeAppModel()
    if let imported {
      try? RimeDeploymentCoordinator(workspace: model.workspace, engine: model.engine)
        .delete(profileID: imported)
      try? FileManager.default.removeItem(at: model.workspace.activeRecord)
    }
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    // The settings round trip writes into the keyboard's user directory and into Documents: both are real
    // places the app uses, so the test puts them back the way it found them.
    for url in userFiles { try? FileManager.default.removeItem(at: url) }
    for url in exports { try? FileManager.default.removeItem(at: url) }
    imported = nil
    scratch = nil
    userFiles = []
    exports = []
  }

  /// What the app does before it is usable: directories, the installation record, the storage policy, an
  /// engine bound to what resolves, and the tracer's typing check as the diagnostic the home screen shows.
  func testTheAppBootstrapsAndBindsAnEngine() async throws {
    let model = RimeAppModel()
    await model.bootstrap()

    XCTAssertNil(model.errorMessage, "bootstrap reported: " + (model.errorMessage ?? ""))
    XCTAssertFalse(model.resolvedSummary.isEmpty, "the app does not say what it resolved")
    XCTAssertTrue(FileManager.default.fileExists(atPath: model.workspace.root.path),
                  "the workspace was never created")
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: model.workspace.userData.appendingPathComponent("installation.yaml").path),
      "the installation record is missing, so the sync directory would move on the next launch")
    XCTAssertFalse(model.engineStatus.contains("尚未启动"),
                   "the engine was never started: " + model.engineStatus)
    XCTAssertFalse(model.engine.isSessionOpen, "the app typing check must not keep shared dictionaries owned")
    XCTAssertNil(RimeLeaseStore(workspace: model.workspace).current(),
                 "the app typing check releases its diagnostic lease")
  }

  func testBootstrapRefreshesAnObsoleteSyncPathAndPreservesTheInstallationID() async throws {
    let model = RimeAppModel()
    let recordURL = model.workspace.installationRecord
    let original = try? Data(contentsOf: recordURL)
    defer {
      model.engine.shutdown()
      if let original { try? original.write(to: recordURL, options: .atomic) }
      else { try? FileManager.default.removeItem(at: recordURL) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    scratch = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let obsolete = directory.appendingPathComponent("old-container")
    try Data("retained".utf8).write(to: obsolete)
    let installation = try model.workspace.setSyncDirectory(obsolete.appendingPathComponent("ArkeySync"))
    await model.bootstrap()
    let current = try XCTUnwrap(model.workspace.loadInstallation())
    XCTAssertEqual(current.installationID, installation.installationID)
    let expected = model.workspace.loadSyncChoice().flatMap { try? $0.validate() }
      ?? RimeSyncLocation.defaultDirectory(workspace: model.workspace)
    XCTAssertEqual(current.syncDirectory, expected.path)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(try Data(contentsOf: obsolete), Data("retained".utf8))
  }

  /// The 配置库 path the screens drive: import a folder, deploy it, and the footer says so. It is the app's
  /// half of S1-AC2 and S2's deploy footer, on the shipped engine.
  func testImportingThenDeployingReportsTheDeployInTheFooter() async throws {
    let model = RimeAppModel()
    await model.bootstrap()

    await model.importPayload(at: try makeSourceFolder(), displayName: "App model test",
                              adoptUserData: false)
    XCTAssertNil(model.errorMessage, "the import reported: " + (model.errorMessage ?? ""))
    let profile = try XCTUnwrap(model.profiles.first { $0.displayName == "App model test" },
                                "the imported profile is not listed: "
                                  + model.profiles.map { $0.displayName }.joined(separator: ", "))
    imported = profile.id

    await model.deploy(profileID: profile.id)

    let message = try XCTUnwrap(model.deployMessage, "the deploy said nothing")
    XCTAssertTrue(message.hasPrefix("部署完成"), "the deploy said: " + message)
    guard case .applied = model.settingsFooter else {
      return XCTFail("the footer is " + String(describing: model.settingsFooter) + " after a deploy")
    }
    XCTAssertEqual(model.activeProfileID, profile.id, "the deploy did not activate what it built")
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: model.workspace.profile(profile.id).build.path), "no build was written")
  }

  func testFileImportAsksBeforeInstallingOrCopyingUserSettings() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    let source = try makeSourceFolder()
    let filename = "confirmation-" + UUID().uuidString + ".custom.yaml"
    let target = model.workspace.userData.appendingPathComponent(filename)
    let contents = Data("patch: {}\n".utf8)
    try contents.write(to: source.appendingPathComponent(filename))
    userFiles = [target]
    var decisions = 0
    await model.importPayload(at: source, displayName: "Confirmed file import", adoptUserData: false) { candidates in
      decisions += 1
      XCTAssertEqual(candidates.map(\.relativePath), [filename])
      XCTAssertTrue(model.isImporting)
      XCTAssertFalse(model.profiles.contains { $0.displayName == "Confirmed file import" })
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
      return true
    }
    imported = model.profiles.first { $0.displayName == "Confirmed file import" }?.id
    XCTAssertEqual(decisions, 1)
    XCTAssertNil(model.errorMessage)
    XCTAssertNotNil(imported)
    XCTAssertEqual(try Data(contentsOf: target), contents)
    XCTAssertFalse(model.isImporting)
  }

  func testCancellingUserSettingsConfirmationAbandonsTheImport() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    let source = try makeSourceFolder()
    let filename = "confirmation-" + UUID().uuidString + ".custom.yaml"
    try Data("patch: {}\n".utf8).write(to: source.appendingPathComponent(filename))
    let existingIDs = model.profiles.map(\.id)
    await model.importPayload(at: source, displayName: "Cancelled file import", adoptUserData: false) { _ in nil }
    imported = model.profiles.first { $0.displayName == "Cancelled file import" }?.id
    XCTAssertNil(imported)
    XCTAssertEqual(model.profiles.map(\.id), existingIDs)
    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.isImporting)
    XCTAssertFalse(FileManager.default.fileExists(atPath: model.workspace.userData.appendingPathComponent(filename).path))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: model.workspace.staging.path).isEmpty)
  }

  func testFileImportWithoutUserSettingsSkipsConfirmation() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    await model.importPayload(at: try makeSourceFolder(), displayName: "Plain file import", adoptUserData: false) { _ in
      XCTFail("a profile without user settings must import without another prompt")
      return nil
    }
    imported = model.profiles.first { $0.displayName == "Plain file import" }?.id
    XCTAssertNotNil(imported)
    XCTAssertNil(model.errorMessage)
  }

  func testDownloadedZIPConfirmsCustomSettingsBeforeInstallation() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    let source = try makeSourceFolder()
    let filename = "download-confirmation-" + UUID().uuidString + ".custom.yaml"
    let contents = Data("patch: {}\n".utf8)
    let target = model.workspace.userData.appendingPathComponent(filename)
    userFiles = [target]
    var writer = RimeZipWriter()
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try writer.addFile(path: file, contents: Data(contentsOf: source.appendingPathComponent(file)))
    }
    try writer.addFile(path: filename, contents: contents)
    let payload = source.appendingPathComponent("download.zip")
    try writer.write(to: payload)
    let origin = RimeProfileSource(kind: .download, url: "https://example.com/profile.zip")

    await model.importPayload(at: payload, displayName: "Cancelled URL import", adoptUserData: false,
                              source: origin) { _ in nil }
    XCTAssertNil(model.downloadResultProfileID)
    XCTAssertFalse(model.profiles.contains { $0.displayName == "Cancelled URL import" })
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

    var confirmations = 0
    await model.importPayload(at: payload, displayName: "Confirmed URL import", adoptUserData: false,
                              source: origin) { candidates in
      confirmations += 1
      XCTAssertEqual(candidates.map(\.relativePath), [filename])
      XCTAssertNil(model.downloadResultProfileID)
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
      return true
    }
    imported = model.profiles.first { $0.displayName == "Confirmed URL import" }?.id
    XCTAssertEqual(confirmations, 1)
    XCTAssertNotNil(imported)
    XCTAssertEqual(model.downloadResultProfileID, imported)
    XCTAssertEqual(try Data(contentsOf: target), contents)
    XCTAssertNil(model.errorMessage)
  }

  func testDeletingADownloadedProfileClearsInstallationAndDeploymentState() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    await model.importPayload(at: try makeSourceFolder(), displayName: "Downloaded deletion test",
      adoptUserData: false,
      source: RimeProfileSource(kind: .download, catalogEntryID: "rime-ice-full"))
    let profile = try XCTUnwrap(model.profiles.first { $0.displayName == "Downloaded deletion test" })
    imported = profile.id
    XCTAssertEqual(model.downloadResultProfileID, profile.id)
    let catalogEntry = try XCTUnwrap(RimeCatalog.standard.entry(id: "rime-ice-full"))
    XCTAssertEqual(model.catalogEntry(for: profile)?.id, catalogEntry.id)
    XCTAssertEqual(model.catalogDownloadAction(for: catalogEntry), .update)
    await model.deploy(profileID: profile.id)
    XCTAssertEqual(model.activeProfileID, profile.id)
    XCTAssertNotNil(model.latestDeployment)

    // A later manual import owns its own warnings; deleting the earlier download must retain them.
    let source = try XCTUnwrap(scratch)
    try Data("patch: {}".utf8).write(to: source.appendingPathComponent("default.custom.yaml"))
    await model.importPayload(at: source, displayName: "Later manual import", adoptUserData: false)
    let later = try XCTUnwrap(model.profiles.first { $0.displayName == "Later manual import" })
    defer { model.delete(profileID: later.id) }
    XCTAssertNotEqual(profile.id, later.id)
    let laterWarnings = model.importWarnings
    XCTAssertFalse(laterWarnings.isEmpty)

    model.delete(profileID: profile.id)

    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.profiles.contains { $0.id == profile.id })
    XCTAssertFalse(model.storage?.profiles.contains { $0.id == profile.id } ?? true)
    XCTAssertNil(model.downloadResultProfileID)
    XCTAssertEqual(model.catalogDownloadAction(for: catalogEntry), .download)
    XCTAssertEqual(model.downloadPhase, .idle)
    XCTAssertNil(model.downloadMessage)
    XCTAssertEqual(model.importWarnings, laterWarnings)
    XCTAssertNil(model.latestDeployment)
    XCTAssertNil(model.deployMessage)
    XCTAssertNil(model.activeProfileID)
    XCTAssertEqual(model.settingsFooter, .unchanged)
    XCTAssertFalse(FileManager.default.fileExists(atPath: model.workspace.profile(profile.id).directory.path))
    XCTAssertEqual(model.resolved?.origin, .bundled)
    try model.engine.openSession()
    defer { model.engine.closeSession() }
    XCTAssertEqual(try model.engine.currentSchema(), "tracer")
  }

  /// Selecting a scheme stays responsive and replaces an imported list with one enabled scheme.
  func testTheSchemaSwitchMovesOnTheTapAndNotWhenTheDeployEnds() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    _ = try await importAndDeployTracer(named: "Schema selection test", into: model,
                                        withAlternativeSchema: true)
    XCTAssertEqual(Set(model.schemaOrderIDs), Set(["tracer", "tracer_alternative"]))

    let tapped = Date()
    model.selectInputSchema("tracer_alternative")
    XCTAssertLessThan(Date().timeIntervalSince(tapped), 0.05, "selection waited for deployment")
    XCTAssertEqual(model.schemaOrderIDs, ["tracer_alternative"])

    await model.waitForSettingsWrites()
    XCTAssertNil(model.errorMessage, "the write reported: " + (model.errorMessage ?? ""))
    XCTAssertEqual(model.schemaOrderIDs, ["tracer_alternative"])
    // The host closes its typing-check session; reopen as the keyboard does on appearance.
    try model.engine.openSession()
    defer { model.engine.closeSession() }
    XCTAssertEqual(try model.engine.currentSchema(), "tracer_alternative")
    XCTAssertEqual(model.schemaDescriptor?.schemaID, "tracer_alternative")
    XCTAssertTrue(model.schemaRows.contains("tracer"), "unselected schemes must remain selectable")

    // Repeated selection cannot disable the scheme or trigger another deployment.
    let revision = model.configurationRevision
    model.selectInputSchema("tracer_alternative")
    model.selectInputSchema("unknown")
    XCTAssertEqual(model.schemaOrderIDs, ["tracer_alternative"])
    XCTAssertEqual(model.configurationRevision, revision)
  }

  /// Rapid selections must deploy the last choice and leave it as the runtime's only scheme.
  func testTappingTheSchemaSwitchTwiceLeavesTheLastChoiceDeployed() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    _ = try await importAndDeployTracer(named: "Schema selection pair test", into: model,
                                        withAlternativeSchema: true)
    model.selectInputSchema("tracer_alternative")
    // Yield so the first writer can start before the next selection arrives.
    await Task.yield()
    model.selectInputSchema("tracer")

    await model.waitForSettingsWrites()
    XCTAssertNil(model.errorMessage, "the writes reported: " + (model.errorMessage ?? ""))
    XCTAssertEqual(model.schemaOrderIDs, ["tracer"])
    try model.engine.openSession()
    defer { model.engine.closeSession() }
    XCTAssertEqual(try model.engine.currentSchema(), "tracer")
    XCTAssertEqual(model.schemaDescriptor?.schemaID, "tracer")
  }

  /// Imports the tracer fixture and deploys it: what every screen below the home screen needs, a live schema to
  /// configure.
  ///
  /// The profile is remembered so tearDown takes it away again, and so is `default.custom.yaml`, which these
  /// tests are about to write. Both are real places the app uses: a `schema_list: []` left in the user directory
  /// is what the next run's deploy would compile, and the suite that found that out failed with "the deployed
  /// profile offers no schema" rather than with anything about the switch.
  private func importAndDeployTracer(named displayName: String,
                                     into model: RimeAppModel,
                                     withAlternativeSchema: Bool = false) async throws -> RimeProfileMetadata {
    // Start from no patch, whatever an earlier run left behind — the same rule the phrase-list test follows. A
    // `schema_list: []` left in this file is what a previous run's switch-off wrote, and the deploy the next run
    // makes compiles exactly that and finds no schema at all: the failure this suite first produced read "the
    // deployed profile offers no schema" and had nothing to do with the switch.
    let patch = model.workspace.userData.appendingPathComponent("default.custom.yaml")
    try? FileManager.default.removeItem(at: patch)
    userFiles.append(patch)
    let source = try makeSourceFolder()
    if withAlternativeSchema {
      let schema = try String(contentsOf: source.appendingPathComponent("tracer.schema.yaml"), encoding: .utf8)
        .replacingOccurrences(of: "schema_id: tracer", with: "schema_id: tracer_alternative")
      try schema.write(to: source.appendingPathComponent("tracer_alternative.schema.yaml"),
                       atomically: true, encoding: .utf8)
      let defaults = source.appendingPathComponent("default.yaml")
      let configuration = try String(contentsOf: defaults, encoding: .utf8)
        .replacingOccurrences(of: "  - schema: tracer", with: "  - schema: tracer\n  - schema: tracer_alternative")
      try configuration.write(to: defaults, atomically: true, encoding: .utf8)
    }
    await model.importPayload(at: source, displayName: displayName, adoptUserData: false)
    let profile = try XCTUnwrap(model.profiles.first { $0.displayName == displayName },
                                "the import is not listed: "
                                  + model.profiles.map { $0.displayName }.joined(separator: ", "))
    imported = profile.id
    await model.deploy(profileID: profile.id)
    await model.refreshSettings()
    return profile
  }

  /// The copy of the bundled profile the importer is given: the three files, without the shipped build
  /// directory, which is the shape the app's folder import expects.
  private func makeSourceFolder() throws -> URL {
    let bundled = try XCTUnwrap(RimeDirectories.bundledSharedDataURL(in: .main), "no bundled RimeData")
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-app-model-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: bundled.appendingPathComponent(file),
                                       to: url.appendingPathComponent(file))
    }
    scratch = url
    return url
  }

  /// S2 §7's portability on the app's own path: the 导出设置 and 导入设置 buttons. A patch and a phrase file are
  /// written where the settings editors write them, exported to one file, deleted, and imported back — the round
  /// trip a user makes between the phone and a Mac.
  func testExportingAndImportingSettingsRoundTrips() async throws {
    let model = RimeAppModel()
    await model.bootstrap()

    let user = model.workspace.userData
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    let patch = user.appendingPathComponent("tracer.custom.yaml")
    let phrases = user.appendingPathComponent("custom_phrase.txt")
    try "patch:\n  translator/enable_completion: false\n".write(to: patch, atomically: true, encoding: .utf8)
    try "你好\tni hao\t1\n".write(to: phrases, atomically: true, encoding: .utf8)
    userFiles = [patch, phrases]

    let exported = try XCTUnwrap(model.exportSettings(), "exportSettings returned no file")
    exports = [exported]
    XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path), "the export wrote no file")
    let exportWarnings = model.importWarnings.joined(separator: " | ")
    XCTAssertTrue(exportWarnings.contains("tracer.custom.yaml") && exportWarnings.contains("custom_phrase.txt"),
                  "the export did not name both files: " + exportWarnings)

    // Take them away so the import has something to restore, and check they are really gone.
    try FileManager.default.removeItem(at: patch)
    try FileManager.default.removeItem(at: phrases)
    XCTAssertFalse(FileManager.default.fileExists(atPath: patch.path))

    await model.importSettingsBundle(from: exported)
    // The import is what is under test. Its redeploy leg then reports that this container has no deployed
    // profile to redeploy into — true here, and a different sentence from a failed import
    // ("导入设置失败：…"), which is the one that would matter.
    if let message = model.errorMessage {
      XCTAssertEqual(message, RimeLocalization.message("No profile is available to deploy."),
                     "the import failed rather than finding nothing to redeploy into: " + message)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: patch.path), "the patch was not restored")
    XCTAssertTrue(FileManager.default.fileExists(atPath: phrases.path), "the phrase file was not restored")
    let restored = try String(contentsOf: patch, encoding: .utf8)
    XCTAssertTrue(restored.contains("enable_completion: false"),
                  "the restored patch is not the one exported: [" + restored + "]")
    // The import's summary names the schemas it touched, not the file names.
    let importWarnings = model.importWarnings.joined(separator: " | ")
    XCTAssertTrue(importWarnings.contains("2 个文件"),
                  "the import did not say how much it restored: " + importWarnings)
    XCTAssertTrue(importWarnings.contains("tracer"),
                  "the import did not name the schema it restored into: " + importWarnings)
  }

  /// The 配置库 lifecycle the screens drive: import, deploy, activate, roll back, delete — with the footer and
  /// the active record as the evidence at each step. The engine's coordinator has its own tests; this is the
  /// app's path through them.
  func testTheProfileLibraryLifecycleOnTheAppsPath() async throws {
    let model = RimeAppModel()
    await model.bootstrap()

    await model.importPayload(at: try makeSourceFolder(), displayName: "Lifecycle test",
                              adoptUserData: false)
    let profile = try XCTUnwrap(model.profiles.first { $0.displayName == "Lifecycle test" },
                                "the import is not listed: "
                                  + model.profiles.map { $0.displayName }.joined(separator: ", "))
    imported = profile.id

    // Deploy twice, so there is a previous generation for the rollback to find.
    await model.deploy(profileID: profile.id)
    XCTAssertTrue((model.deployMessage ?? "").hasPrefix("部署完成"),
                  "the first deploy said: " + (model.deployMessage ?? "nothing"))
    let firstAttempt = try XCTUnwrap(model.latestDeployment)
    XCTAssertEqual(firstAttempt.profileID, profile.id)
    XCTAssertEqual(firstAttempt.profileName, "Lifecycle test")
    XCTAssertNotNil(firstAttempt.finishedAt)
    XCTAssertFalse(firstAttempt.failed)
    await model.deploy(profileID: profile.id)
    let secondAttempt = try XCTUnwrap(model.latestDeployment)
    XCTAssertNotEqual(firstAttempt.id, secondAttempt.id)
    XCTAssertFalse(secondAttempt.logs.isEmpty, "the deployment report should retain engine diagnostics")
    model.engine.logBuffer.removeAll()
    model.engine.logBuffer.append(RimeLogRecord(severity: .info, message: "Unrelated typing log",
                                               file: "test", line: 1))
    XCTAssertEqual(model.latestDeployment?.logs, secondAttempt.logs,
                   "later engine activity must not replace deployment diagnostics")

    model.activate(profileID: profile.id)
    XCTAssertEqual(model.latestDeployment?.message, secondAttempt.message,
                   "activation must not relabel the deployment result")
    XCTAssertNil(model.errorMessage, "activation reported: " + (model.errorMessage ?? ""))
    XCTAssertEqual(model.settingsFooter, .applied(RimeLocalization.message("Profile changed")),
                   "the footer after activating: " + String(describing: model.settingsFooter))
    XCTAssertTrue((model.deployMessage ?? "").contains("已切换"),
                  "activation said: " + (model.deployMessage ?? "nothing"))
    let active = try? model.workspace.loadActiveProfile()
    XCTAssertEqual(active?.profileID, profile.id,
                   "the active record does not point at the activated profile")

    model.rollback(profileID: profile.id)
    if model.errorMessage == nil {
      XCTAssertEqual(model.settingsFooter, .applied(RimeLocalization.message("Rolled back to the previous build")),
                     "the footer after rolling back: " + String(describing: model.settingsFooter))
    }

    model.delete(profileID: profile.id)
    XCTAssertNil(model.errorMessage, "deletion reported: " + (model.errorMessage ?? ""))
    XCTAssertFalse(model.profiles.contains { $0.id == profile.id },
                   "the profile is still listed after deletion")
    imported = nil
  }

  func testDeploymentFailureDoesNotReuseUnrelatedEngineLogs() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    let missingProfileID = "missing-" + UUID().uuidString
    model.engine.logBuffer.append(RimeLogRecord(severity: .error, message: "Unrelated error",
                                               file: "test", line: 1))
    await model.deploy(profileID: missingProfileID)
    let attempt = try XCTUnwrap(model.latestDeployment)
    XCTAssertEqual(attempt.profileID, missingProfileID)
    XCTAssertTrue(attempt.failed)
    XCTAssertNotNil(attempt.finishedAt)
    XCTAssertEqual(attempt.message, model.errorMessage)
    XCTAssertTrue(attempt.logs.isEmpty, "an early failure has no deployment report")
    XCTAssertFalse(model.isDeploying)
  }

  /// S2 §3's rule at the app level: the keyboard's own settings never need a deploy, so writing one leaves the
  /// footer alone. Without the App Group the store is unavailable — true in this test host, and the sentence the
  /// user would see — so the write reports that and changes nothing, rather than pretending to have saved.
  func testKeyboardPreferencesDoNotAskForADeploy() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    let before = model.keyboardPreferences

    model.updatePreferences { $0.paletteMode = .fixed }

    if model.preferencesStore == nil {
      XCTAssertEqual(model.errorMessage, RimeLocalization.message("App Group is unavailable; keyboard settings cannot be shared with the keyboard."),
                     "the write reported: " + (model.errorMessage ?? "nothing"))
      XCTAssertEqual(model.keyboardPreferences, before, "the settings changed without a store")
    } else {
      XCTAssertNil(model.errorMessage, "the write reported: " + (model.errorMessage ?? ""))
      XCTAssertEqual(model.keyboardPreferences.paletteMode, .fixed,
                     "the settings were not saved through the app group")
      await model.resetPreferences()
    }
    XCTAssertEqual(model.settingsFooter, .unchanged,
                   "a keyboard setting asked for a deploy: " + String(describing: model.settingsFooter))
  }

  /// S2 §3's 自定义短语 row on the app's own path: the list is the user's file, in Rime's own format, because
  /// the desktop and the phone exchange it as plain text and a user who prefers an editor keeps working.
  func testTheCustomPhraseListRoundTripsThroughRimesFile() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    userFiles = [model.customPhraseURL]

    // Start from an empty list, whatever an earlier run left behind.
    await model.saveCustomPhrases([])
    await model.addCustomPhrase(text: "你好", code: "nihao", weight: 1)

    XCTAssertTrue(model.customPhrases.contains { $0.text == "你好" && $0.code == "nihao" },
                  "the list does not hold what was added: "
                    + model.customPhrases.map { $0.text + "/" + $0.code }.joined(separator: ", "))

    // Rime's interchange format: one phrase per line, tab-separated fields, weight optional and last. The
    // desktop reads this file with another editor, so the separators are not an implementation detail.
    let written = try String(contentsOf: model.customPhraseURL, encoding: .utf8)
    XCTAssertTrue(written.hasSuffix("\n"), "the file does not end with a newline: [" + written + "]")
    let fields = written.trimmingCharacters(in: .newlines)
      .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    XCTAssertEqual(fields.count, 3, "the line is not text<TAB>code<TAB>weight: [" + written + "]")
    XCTAssertEqual(fields.first, "你好")
    XCTAssertEqual(fields.dropFirst().first, "nihao")
    XCTAssertEqual(fields.count > 2 ? Double(fields[2]) : nil, 1,
                   "the weight is not on the line: [" + written + "]")

    let index = try XCTUnwrap(model.customPhrases.firstIndex { $0.text == "你好" && $0.code == "nihao" },
                              "the phrase is not in the list")
    await model.removeCustomPhrase(at: IndexSet(integer: index))
    XCTAssertFalse(model.customPhrases.contains { $0.text == "你好" },
                   "the phrase is still listed: "
                     + model.customPhrases.map { $0.text }.joined(separator: ", "))
    let emptied = try String(contentsOf: model.customPhraseURL, encoding: .utf8)
    XCTAssertFalse(emptied.contains("你好"), "the phrase is still in the file: [" + emptied + "]")

    // Writing a phrase deploys it, and this container has no profile to deploy into — the same sentence the
    // settings import reports, and not a failure to write the file.
    if let message = model.errorMessage {
      XCTAssertEqual(message, RimeLocalization.message("No profile is available to deploy."),
                     "writing the phrase reported: " + message)
    }
  }
}
