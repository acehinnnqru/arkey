import XCTest
@testable import RimeEngine

/// S5's engine-side evidence: the two text formats, conflict-copy tolerance, the lease, and the
/// whole phone-side path from learning a word to a snapshot in the sync folder.
final class S5UserDictionaryTests: XCTestCase {
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
      .appendingPathComponent("arkey-s5", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()
    _ = try workspace.seedInstallation(syncDirectory: scratch.appendingPathComponent("sync", isDirectory: true))

    let source = scratch.appendingPathComponent("profile", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file),
                                       to: source.appendingPathComponent(file))
    }
    // The tracer ships with learning off; S5's whole subject is what happens when it is on.
    let schema = try String(contentsOf: source.appendingPathComponent("tracer.schema.yaml"), encoding: .utf8)
    try schema.replacingOccurrences(of: "enable_user_dict: false", with: "enable_user_dict: true")
      .write(to: source.appendingPathComponent("tracer.schema.yaml"), atomically: true, encoding: .utf8)

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

  // MARK: The two formats

  func testTheSyncSnapshotFormatParses() throws {
    let text = """
    # Rime user dictionary
    #@/db_name\ttracer
    #@/db_type\tuserdb
    #@/rime_version\t1.17.0
    #@/tick\t42
    #@/user_id\tPHONE-AAAA
    ni hao\t你好\tc=2 d=1 t=42
    shu ru fa\t输入法\tc=1 d=0 t=41

    """
    let snapshot = try XCTUnwrap(RimeUserDictionarySnapshot.parse(text: text))
    XCTAssertEqual(snapshot.dictionary, "tracer")
    XCTAssertEqual(snapshot.databaseType, "userdb")
    XCTAssertEqual(snapshot.rimeVersion, "1.17.0")
    XCTAssertEqual(snapshot.tick, 42)
    XCTAssertEqual(snapshot.userID, "PHONE-AAAA")
    XCTAssertEqual(snapshot.entries.count, 2)
    XCTAssertEqual(snapshot.entries[0], .init(code: "ni hao", text: "你好", commits: 2, deletions: 1, tick: 42))
  }

  /// The levers export is a different shape; refusing it as a snapshot is the point.
  func testTheLeversExportIsADifferentFormatAndIsNotASnapshot() throws {
    let export = """
    # Rime user dictionary export
    你好\tni hao\t2
    输入法\tshu ru fa\t1

    """
    XCTAssertNil(RimeUserDictionarySnapshot.parse(text: export),
                 "a levers export dropped into the sync folder must be refused, not half-read")
    let parsed = try XCTUnwrap(RimeUserDictionaryExport.parse(text: export))
    XCTAssertEqual(parsed.entries.count, 2)
    XCTAssertEqual(parsed.entries[0], .init(text: "你好", code: "ni hao", weight: 2))
  }

  func testConflictCopiesAreToleratedAsNormalFiles() {
    XCTAssertEqual(RimeSyncDiscovery.dictionaryName(fromFileName: "rime_ice.userdb.txt"), "rime_ice")
    XCTAssertEqual(RimeSyncDiscovery.dictionaryName(fromFileName: "rime_ice.userdb 2.txt"), "rime_ice")
    XCTAssertEqual(RimeSyncDiscovery.dictionaryName(fromFileName: "rime_ice.userdb (1).txt"), "rime_ice")
    // A name that merely ends in a number is a dictionary name, not a copy.
    XCTAssertEqual(RimeSyncDiscovery.dictionaryName(fromFileName: "rime_ice-2.userdb.txt"), "rime_ice-2")
    XCTAssertNil(RimeSyncDiscovery.dictionaryName(fromFileName: "notes.txt"))
    XCTAssertNil(RimeSyncDiscovery.dictionaryName(fromFileName: "rime_ice.userdb"))

    XCTAssertFalse(RimeSyncDiscovery.isConflictCopy(fileName: "rime_ice.userdb.txt"))
    XCTAssertTrue(RimeSyncDiscovery.isConflictCopy(fileName: "rime_ice.userdb 2.txt"))
  }

  func testSnapshotsAreDiscoveredAcrossDevices() throws {
    let sync = scratch.appendingPathComponent("sync", isDirectory: true)
    for device in ["PHONE", "MAC"] {
      let directory = sync.appendingPathComponent(device, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try """
    # Rime user dictionary
    #@/db_name\ttracer
    #@/user_id\tPHONE
    ni hao\t你好\tc=1 d=0 t=1

    """.write(to: sync.appendingPathComponent("PHONE/tracer.userdb.txt"), atomically: true, encoding: .utf8)
    try """
    # Rime user dictionary
    #@/db_name\ttracer
    #@/user_id\tMAC
    shu ru fa\t输入法\tc=3 d=0 t=9

    """.write(to: sync.appendingPathComponent("MAC/tracer.userdb.txt"), atomically: true, encoding: .utf8)
    // iCloud's habit: a conflict copy beside the real file.
    try "conflict".write(to: sync.appendingPathComponent("MAC/tracer.userdb 2.txt"),
                         atomically: true, encoding: .utf8)

    let found = RimeSyncDiscovery.snapshots(in: sync)
    XCTAssertEqual(found.count, 3)
    XCTAssertEqual(found.map(\.deviceID).sorted(), ["MAC", "MAC", "PHONE"])
    XCTAssertEqual(found.filter { $0.isConflictCopy }.count, 1)

    let report = try RimeSyncService(workspace: workspace, engine: engine).report()
    let entry = try XCTUnwrap(report.dictionaries.first { $0.name == "tracer" })
    // This workspace's own installation id is the seeded UUID, so both fixture directories are
    // other devices — which is what a merge reads.
    XCTAssertEqual(entry.otherDevices.map(\.deviceID), ["MAC", "PHONE"])
    XCTAssertEqual(entry.conflictCopies, 1)
    XCTAssertEqual(report.installationID, workspace.loadInstallation()?.installationID)
  }

  // MARK: The lease

  func testTheLeaseIsWarmWhileTheKeyboardHoldsItAndColdWhenItDoesNot() throws {
    let store = RimeLeaseStore(workspace: workspace)
    XCTAssertTrue(store.isCold(), "no lease file means nobody is typing")

    try store.claim(pid: getpid())
    XCTAssertNotNil(store.liveHolder())
    XCTAssertFalse(store.isCold())

    // Metadata written without kernel ownership is diagnostic only; its freshness can age out.
    let later = Date().addingTimeInterval(RimeKeyboardLease.staleAfter + 1)
    XCTAssertTrue(store.isCold(now: later))
    XCTAssertNil(store.liveHolder(now: later))

    // A process that is gone is cold even with a fresh heartbeat.
    let dead = try store.claim(pid: 999_999, host: "phone")
    XCTAssertEqual(dead.pid, 999_999)
    XCTAssertNil(store.liveHolder(), "a lease from a process that no longer exists is not a holder")

    store.prune()
    XCTAssertNil(store.current())

    try store.claim(pid: getpid())
    store.release()
    XCTAssertNil(store.current())

    // A late heartbeat must not resurrect it: the keyboard releases at dismissal, and a timer that
    // fires afterwards cannot re-block the app's dictionary work.
    store.heartbeat(pid: getpid())
    XCTAssertNil(store.current())
    XCTAssertTrue(store.isCold())
  }

  /// The lease failure mode that used to be invisible: a file that cannot be read. "We cannot tell" is
  /// not "nobody is typing" — the leveldb lock does not care why we are wrong — so it counts as held
  /// while it is fresh, with the file's modification date standing in for the heartbeat it cannot
  /// provide, and it ages out like any other instead of wedging the app forever.
  func testAnUnreadableLeaseIsHeldWhileFreshAndAgesOut() throws {
    let store = RimeLeaseStore(workspace: workspace)
    let url = workspace.root.appendingPathComponent("keyboard.lease.json")
    try Data("this is not a lease".utf8).write(to: url)

    guard case .unreadable = store.state() else {
      return XCTFail("expected an unreadable state, got " + String(describing: store.state()))
    }
    XCTAssertFalse(store.isCold(), "a fresh unreadable lease is not safe to proceed past")

    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    guard case .unreadableLease = access.blocker() else {
      return XCTFail("expected an unreadableLease blocker")
    }
    XCTAssertThrowsError(try access.requireExclusiveAccess()) { error in
      guard case RimeDictionaryAccessError.leaseUnreadable = error else {
        return XCTFail("expected leaseUnreadable, got " + String(describing: error))
      }
    }

    // The report carries the same sentence the screen shows, and does not call it "cold".
    let report = try RimeSyncService(workspace: workspace, engine: engine).report()
    XCTAssertFalse(report.isLeaseCold)
    XCTAssertNotNil(report.leaseBlocker)

    // Fresh garbage is left alone by the prune...
    store.prune()
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    // ...but a file that is both unreadable and old has aged out: cold, no blocker, and pruned.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                          ofItemAtPath: url.path)
    XCTAssertEqual(store.state(), .cold)
    XCTAssertTrue(store.isCold())
    XCTAssertNil(access.blocker())
    store.prune()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                   "an unreadable lease that aged out is removed, not left as a ghost")
  }

  /// A lease written by a schema version this build does not know is the same case as garbage: not
  /// readable, so not evidence that nobody is typing.
  func testALeaseFromANewerSchemaIsNotTreatedAsCold() throws {
    let store = RimeLeaseStore(workspace: workspace)
    let url = workspace.root.appendingPathComponent("keyboard.lease.json")
    var lease = RimeKeyboardLease(pid: getpid())
    lease.schemaVersion = RimeKeyboardLease.currentSchemaVersion + 1
    try RimeJSON.encode(lease).write(to: url)

    guard case .unreadable = store.state(now: lease.heartbeat) else {
      return XCTFail("expected an unreadable state for a newer schema")
    }
    XCTAssertFalse(store.isCold(now: lease.heartbeat))
  }

  func testTheAppRefusesDictionaryWorkWhileTheKeyboardHoldsTheLease() throws {
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    XCTAssertNil(access.blocker())

    let store = RimeLeaseStore(workspace: workspace, liveness: { _ in true })
    let accessWithLivePID = RimeDictionaryAccess(workspace: workspace, engine: engine, leaseStore: store)
    try engine.openSession()
    try store.claim(pid: 999_998)

    XCTAssertThrowsError(try accessWithLivePID.requireExclusiveAccess()) { error in
      guard case RimeDictionaryAccessError.keyboardIsUsingIt(let pid, _) = error else {
        return XCTFail("expected keyboardIsUsingIt, got \(error)")
      }
      XCTAssertEqual(pid, 999_998)
    }

    // This fixture writes metadata without acquiring ownership. A stale diagnostic file does not
    // block the advisory check; a real session's kernel lock is tested separately below.
    XCTAssertNil(access.blocker(now: Date().addingTimeInterval(RimeKeyboardLease.staleAfter + 1)))

    // The gate closes the app's own session while the operation runs and restores it afterwards.
    store.release()
    let access2 = RimeDictionaryAccess(workspace: workspace, engine: engine)
    XCTAssertTrue(engine.isSessionOpen)
    var sessionDuringOperation = true
    try access2.perform { sessionDuringOperation = engine.isSessionOpen }
    XCTAssertFalse(sessionDuringOperation, "export needs no session holding the database")
    XCTAssertTrue(engine.isSessionOpen, "and the app's session comes back")
  }

  private func bindEngineToDictionaryLock() throws -> RimeLeaseStore {
    let directories = engine.directories
    engine.shutdown()
    let store = RimeLeaseStore(workspace: workspace)
    engine = RimeEngine(configuration: RimeConfiguration(directories: directories),
                        dictionaryLeaseStore: store, dictionaryHost: "keyboard")
    try engine.start()
    return store
  }

  func testSessionOwnershipSurvivesStaleMissingAndCorruptMetadata() throws {
    let store = try bindEngineToDictionaryLock()
    try engine.openSession()
    defer { engine.closeSession() }
    let access = RimeDictionaryAccess(workspace: workspace,
                                      engine: RimeEngine(configuration: RimeConfiguration(directories: engine.directories)))
    try store.claim(now: Date().addingTimeInterval(-3600))
    XCTAssertNotNil(access.blocker())
    XCTAssertThrowsError(try store.acquireLock())
    store.prune()
    XCTAssertNotNil(store.current(), "pruning cannot remove a suspended holder's metadata")
    try FileManager.default.removeItem(at: store.url)
    XCTAssertNotNil(access.blocker(), "missing diagnostics do not release ownership")
    try Data("invalid metadata".utf8).write(to: store.url)
    XCTAssertThrowsError(try access.perform { XCTFail("a competitor entered the operation") })
    XCTAssertTrue(engine.isSessionOpen)
  }

  func testAnIdleVisibleSessionRenewsItsDiagnosticHeartbeat() throws {
    let store = try bindEngineToDictionaryLock()
    try engine.openSession()
    defer { engine.closeSession() }
    let first = try XCTUnwrap(store.current()).heartbeat
    let renewed = expectation(description: "the session heartbeat timer runs without input")
    DispatchQueue.global().asyncAfter(deadline: .now() + 6) { renewed.fulfill() }
    wait(for: [renewed], timeout: 8)
    XCTAssertGreaterThan(try XCTUnwrap(store.current()).heartbeat, first)
    XCTAssertThrowsError(try store.acquireLock())
  }

  func testClosingAndReopeningASessionReacquiresOwnership() throws {
    let store = try bindEngineToDictionaryLock()
    try engine.openSession()
    XCTAssertThrowsError(try store.acquireLock())
    engine.closeSession()
    XCTAssertFalse(engine.isSessionOpen)
    XCTAssertNil(store.current())
    var competitor: RimeDictionaryLock? = try store.acquireLock()
    XCTAssertThrowsError(try engine.openSession())
    XCTAssertFalse(engine.isSessionOpen, "a denied claim must not open a session")
    withExtendedLifetime(competitor) {}
    competitor = nil
    try engine.openSession()
    XCTAssertNotNil(store.current(), "reappearance claims new metadata")
    XCTAssertTrue(engine.isSessionOpen)
    XCTAssertThrowsError(try store.acquireLock())
    engine.closeSession()
    XCTAssertNoThrow(try store.acquireLock())
  }

  func testDictionaryOperationKeepsOwnershipAcrossCloseAndRestoreAndErrors() throws {
    let store = try bindEngineToDictionaryLock()
    try engine.openSession()
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    enum Failure: Error { case expected }
    XCTAssertThrowsError(try access.perform {
      XCTAssertFalse(engine.isSessionOpen)
      XCTAssertThrowsError(try store.acquireLock(), "closing for export must not release ownership")
      throw Failure.expected
    })
    XCTAssertTrue(engine.isSessionOpen, "a throwing operation restores the session under the lock")
    XCTAssertThrowsError(try store.acquireLock())
    engine.closeSession()
    try access.perform {
      XCTAssertThrowsError(try store.acquireLock())
    }
    XCTAssertFalse(engine.isSessionOpen, "an initially closed session stays closed")
    XCTAssertNoThrow(try store.acquireLock())
    XCTAssertNil(store.current())
  }

  func testAClaimFailureDoesNotOpenASessionOrLeakOwnership() throws {
    let store = try bindEngineToDictionaryLock()
    try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
    XCTAssertThrowsError(try engine.openSession(), "diagnostic claim failure must fail closed")
    XCTAssertFalse(engine.isSessionOpen)
    XCTAssertNoThrow(try store.acquireLock(), "a failed claim must release the descriptor")
    try FileManager.default.removeItem(at: store.url)
    try engine.openSession()
    XCTAssertTrue(engine.isSessionOpen, "a repaired claim can acquire and open normally")
    engine.closeSession()
  }

  func testAnOperationCannotEnterAfterAnAdvisoryCheckRacesWithAClaim() throws {
    let store = RimeLeaseStore(workspace: workspace)
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    try access.requireExclusiveAccess()
    let competitor = try store.acquireLock()
    // No metadata is written: the kernel lock alone must close the check/execute gap.
    XCTAssertThrowsError(try access.perform { XCTFail("operation raced past the lock") })
    withExtendedLifetime(competitor) {}
  }

  // MARK: The whole phone-side path

  func testALearnedWordReachesTheExportAndTheSyncSnapshot() async throws {
    try engine.openSession()
    let composed = try engine.processKeys("shurufa")
    XCTAssertEqual(composed.candidates.first?.text, "输入法")
    XCTAssertEqual(try engine.selectCandidate(at: 0).commit, "输入法")

    // Learning writes the user dictionary at commit time.
    let names = try engine.userDictionaryNames()
    XCTAssertTrue(names.contains("tracer"), "expected a user dictionary for tracer, got \(names)")
    let database = workspace.userData.appendingPathComponent("tracer.userdb", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))

    // Export needs the session closed — the measured precondition, which the access gate performs.
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    let exportURL = scratch.appendingPathComponent("tracer.export.txt")
    let count = try access.perform { try engine.exportUserDictionary("tracer", to: exportURL) }
    XCTAssertGreaterThan(count, 0)
    let exportText = try String(contentsOf: exportURL, encoding: .utf8)
    let export = try XCTUnwrap(RimeUserDictionaryExport.parse(text: exportText))
    XCTAssertTrue(export.entries.contains { $0.text == "输入法" },
                  export.entries.map(\.text).joined(separator: ","))

    // Measured, and it is S5 §3.2 in one line: backup_user_dict fails while a session is open —
    // the leveldb lock — and writes the file once the session is closed.
    XCTAssertFalse(try engine.backupUserDictionary("tracer"),
                   "a session holds the user dictionary, so librime cannot read it")
    let service = RimeSyncService(workspace: workspace, engine: engine)
    // The roadmap's measured property: installation.yaml's absolute sync_dir is honoured, so the
    // snapshot directory is absolute rather than a sync/ relative to the working directory.
    let resolvedSyncDirectory = try XCTUnwrap(engine.userDataSyncDirectory())
    XCTAssertTrue(resolvedSyncDirectory.hasPrefix("/"),
                  "librime resolved a relative sync directory: " + resolvedSyncDirectory)
    XCTAssertEqual(URL(fileURLWithPath: resolvedSyncDirectory).lastPathComponent,
                   workspace.loadInstallation()?.installationID)
    XCTAssertEqual(URL(fileURLWithPath: resolvedSyncDirectory).deletingLastPathComponent().path,
                   scratch.appendingPathComponent("sync").path)
    let outcome = try service.syncNow()
    XCTAssertTrue(outcome.succeeded, outcome.failureReason ?? "")
    XCTAssertTrue(engine.isSessionOpen, "the sync borrows the session and gives it back")
    let device = try XCTUnwrap(service.deviceDirectory)
    let snapshotURL = device.appendingPathComponent("tracer.userdb.txt")
    XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                  "expected a snapshot at \(snapshotURL.path); sync wrote "
                    + String(outcome.snapshotCount) + " snapshots")
    let snapshot = try XCTUnwrap(RimeUserDictionarySnapshot.parse(
      text: try String(contentsOf: snapshotURL, encoding: .utf8)))
    XCTAssertTrue(snapshot.entries.contains { $0.text == "输入法" },
                  snapshot.entries.map(\.text).joined(separator: ","))
    XCTAssertEqual(snapshot.dictionary, "tracer")
  }
  // MARK: Backups (S5 §4, §10)

  func testABackupSitsBesideTheSnapshotAndKeepsTheLastThree() async throws {
    try engine.openSession()
    _ = try engine.processKeys("shurufa")
    _ = try engine.selectCandidate(at: 0)
    engine.closeSession()

    let service = RimeSyncService(workspace: workspace, engine: engine)
    let outcome = try service.syncNow()
    XCTAssertTrue(outcome.succeeded, outcome.failureReason ?? "")
    let device = try XCTUnwrap(service.deviceDirectory)
    let live = device.appendingPathComponent("tracer.userdb.txt")
    XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    // The sync archived the snapshot it was about to write, so the pre-sync state is already kept.
    let syncArchived = service.backups(for: "tracer").map(\.lastPathComponent)
    XCTAssertEqual(syncArchived.count, 1, "one backup per sync, not one per dictionary")

    // Five changes, five files — named the way §4 names them, and all in the device's own folder
    // rather than somewhere the user has to be told about.
    let base = Date(timeIntervalSince1970: 1_760_000_000)
    var written: [String] = []
    for step in 0..<5 {
      let url = try XCTUnwrap(try service.backup(dictionary: "tracer",
                                                 now: base.addingTimeInterval(Double(step))))
      XCTAssertEqual(url.deletingLastPathComponent().path, device.path)
      written.append(url.lastPathComponent)
    }
    XCTAssertEqual(Set(written).count, 5, "five timestamps are five files")
    XCTAssertTrue(written.allSatisfy { $0.hasPrefix("tracer.userdb.") && $0.hasSuffix(".txt") },
                  written.joined(separator: ", "))

    let kept = service.backups(for: "tracer")
    XCTAssertEqual(kept.map(\.lastPathComponent), syncArchived + Array(written.suffix(2).reversed()),
                   "the last three, newest first — the two oldest of the five are gone")
    XCTAssertFalse(kept.contains { $0.lastPathComponent == "tracer.userdb.txt" },
                   "the live snapshot is not a backup of itself")
    let pruned = try service.pruneBackups(dictionary: "tracer", keeping: 1)
    XCTAssertEqual(pruned.map(\.lastPathComponent), Array(kept.dropFirst()).map(\.lastPathComponent))
    XCTAssertEqual(service.backups(for: "tracer").count, 1)

    // The file is the snapshot format, not the levers export: a restore reads it without conversion.
    let newest = try XCTUnwrap(service.backups(for: "tracer").first)
    let text = try String(contentsOf: newest, encoding: .utf8)
    let snapshot = try XCTUnwrap(RimeUserDictionarySnapshot.parse(text: text))
    XCTAssertEqual(snapshot.dictionary, "tracer")
    XCTAssertTrue(snapshot.entries.contains { $0.text == "输入法" },
                  snapshot.entries.map(\.text).joined(separator: ","))

    // And discovery still sees exactly one snapshot for this device: a backup is not a second one.
    let myID = try XCTUnwrap(service.installationID)
    let discovered = RimeSyncDiscovery.snapshots(in: try XCTUnwrap(service.syncDirectory))
      .filter { $0.dictionary == "tracer" && $0.deviceID == myID }
    XCTAssertEqual(discovered.count, 1, discovered.map(\.url.lastPathComponent).joined(separator: ", "))
    XCTAssertEqual(discovered.first?.url.lastPathComponent, "tracer.userdb.txt")
  }

  func testARestoreBringsBackTheWordABackupHolds() async throws {
    try engine.openSession()
    _ = try engine.processKeys("shurufa")
    _ = try engine.selectCandidate(at: 0)
    engine.closeSession()

    let service = RimeSyncService(workspace: workspace, engine: engine)
    _ = try service.syncNow()
    let backup = try XCTUnwrap(try service.backup(dictionary: "tracer"))

    // A botched merge, or a delete the user regrets: the dictionary is gone, the backup is not.
    XCTAssertTrue(try RimeDictionaryEditor(workspace: workspace, engine: engine)
      .removeDictionary("tracer"))
    _ = try RimeDictionaryAccess(workspace: workspace, engine: engine)
      .perform { try engine.restoreUserDictionary(snapshotFile: backup) }

    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    let exportURL = scratch.appendingPathComponent("after-restore.txt")
    _ = try access.perform { try engine.exportUserDictionary("tracer", to: exportURL) }
    let export = try XCTUnwrap(RimeUserDictionaryExport.parse(
      text: try String(contentsOf: exportURL, encoding: .utf8)))
    XCTAssertTrue(export.entries.contains { $0.text == "输入法" },
                  export.entries.map(\.text).joined(separator: ","))

    // A sync takes the backup itself, so the pre-sync state survives the overwrite.
    _ = try service.syncNow()
    XCTAssertFalse(service.backups(for: "tracer").isEmpty,
                   "a sync archives the snapshot it is about to replace")
  }

  func testAMergeAddsAnotherDevicesWordsAndKeepsOurs() async throws {
    // This device learns 输入法 and syncs, which is what puts a snapshot in the shared folder.
    try engine.openSession()
    _ = try engine.processKeys("shurufa")
    _ = try engine.selectCandidate(at: 0)
    engine.closeSession()
    let service = RimeSyncService(workspace: workspace, engine: engine)
    _ = try service.syncNow()

    // Another device's snapshot, written the way librime writes one, holding a word this device never
    // learned — 世界, whose code the tracer's prism knows.
    let sync = try XCTUnwrap(service.syncDirectory)
    let other = sync.appendingPathComponent("BBBB", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let snapshot = """
    # Rime user dictionary
    #@/db_name\ttracer
    #@/db_type\tuserdb
    #@/rime_version\t1.17.0
    #@/tick\t1
    #@/user_id\tother
    shi jie\t世界\tc=4 d=0 t=1
    """
    try snapshot.write(to: other.appendingPathComponent("tracer.userdb.txt"),
                       atomically: true, encoding: .utf8)

    let outcome = try service.mergeFromOtherDevices()
    XCTAssertEqual(outcome.entries.map(\.dictionary), ["tracer"])
    XCTAssertEqual(outcome.entries.first?.deviceIDs, ["BBBB"])
    XCTAssertEqual(outcome.entries.first?.entriesRead, 1)
    XCTAssertGreaterThan(outcome.totalImported, 0, "librime reported importing nothing")
    XCTAssertNotNil(outcome.entries.first?.backup, "the merge archives before it writes")

    // Both words are there: the import is additive, which is the whole point of a merge.
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    let exportURL = scratch.appendingPathComponent("after-merge.txt")
    _ = try access.perform { try engine.exportUserDictionary("tracer", to: exportURL) }
    let export = try XCTUnwrap(RimeUserDictionaryExport.parse(
      text: try String(contentsOf: exportURL, encoding: .utf8)))
    let texts = export.entries.map(\.text).joined(separator: ",")
    XCTAssertTrue(export.entries.contains { $0.text == "输入法" }, texts)
    XCTAssertTrue(export.entries.contains { $0.text == "世界" }, texts)

    // Nothing left behind in staging, and the other device's own file is untouched.
    let staging = workspace.staging.appendingPathComponent("sync-import", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: other.appendingPathComponent("tracer.userdb.txt").path))
  }

  /// S5 §9: the other devices are separate sources with their own timestamp, and the user merges the
  /// ones they trust — one at a time.
  func testTheOtherDevicesAreListedWithTheirTimestampAndMergeOneAtATime() async throws {
    let service = RimeSyncService(workspace: workspace, engine: engine)
    let sync = try XCTUnwrap(service.syncDirectory)

    func writeSnapshot(device: String, word: String, code: String) throws {
      let directory = sync.appendingPathComponent(device, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let text = """
      # Rime user dictionary
      #@/db_name\ttracer
      #@/db_type\tuserdb
      #@/rime_version\t1.17.0
      #@/tick\t1
      #@/user_id\t\(device)
      \(code)\t\(word)\tc=4 d=0 t=1
      """
      try text.write(to: directory.appendingPathComponent("tracer.userdb.txt"),
                     atomically: true, encoding: .utf8)
    }
    try writeSnapshot(device: "MAC", word: "世界", code: "shi jie")
    try writeSnapshot(device: "PHONE", word: "中文", code: "zhong wen")

    let report = try service.report()
    let entry = try XCTUnwrap(report.dictionaries.first { $0.name == "tracer" },
                              report.dictionaries.map(\.name).joined(separator: ","))
    XCTAssertEqual(entry.otherDevices.map(\.deviceID), ["MAC", "PHONE"])
    XCTAssertEqual(entry.otherDevices.map(\.bytes), [entry.otherDevices[0].bytes,
                                                      entry.otherDevices[1].bytes])
    for device in entry.otherDevices {
      XCTAssertGreaterThan(device.bytes, 0, "the row carries the file size")
      XCTAssertLessThan(abs(device.modifiedAt.timeIntervalSinceNow), 60,
                        "and when the snapshot was taken, not the epoch")
      XCTAssertFalse(device.isConflictCopy, device.deviceID + " is a plain snapshot")
    }

    // Merge MAC only: the user's choice, not the folder's contents.
    let outcome = try service.mergeFromOtherDevices(devices: ["MAC"])
    XCTAssertEqual(outcome.entries.map(\.dictionary), ["tracer"])
    XCTAssertEqual(outcome.entries.first?.deviceIDs, ["MAC"])

    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    let exportURL = scratch.appendingPathComponent("after-one-device-merge.txt")
    _ = try access.perform { try engine.exportUserDictionary("tracer", to: exportURL) }
    let export = try XCTUnwrap(RimeUserDictionaryExport.parse(
      text: try String(contentsOf: exportURL, encoding: .utf8)))
    let texts = export.entries.map(\.text).joined(separator: ",")
    XCTAssertTrue(export.entries.contains { $0.text == "世界" }, texts)
    XCTAssertFalse(export.entries.contains { $0.text == "中文" },
                   "PHONE was not merged: " + texts)
  }

  /// S5 §9's corrupt-database row, **measured** in round 110 before it was implemented: librime logs
  /// `Error opening db '<name>': Corruption: …` and then `… read-only`, rebuilds the database **in
  /// place** — nothing is renamed, and nothing is restored from the sync folder — and keeps running, with
  /// the schema still typing from the base dictionary. So the app's half of the row is "surface the
  /// event": librime's own line, in the report and on the screen.
  func testACorruptDictionaryIsReportedWithLibrimesOwnReason() async throws {
    try engine.openSession()
    _ = try engine.processKeys("shurufa")
    _ = try engine.selectCandidate(at: 0)
    engine.closeSession()

    // The negative control: a healthy start has nothing to report.
    XCTAssertTrue(engine.databaseIssues().isEmpty,
                  engine.databaseIssues().map(\.message).joined(separator: " | "))
    let healthy = try RimeSyncService(workspace: workspace, engine: engine).report()
    XCTAssertFalse(try XCTUnwrap(healthy.dictionaries.first { $0.name == "tracer" }).isDamaged)

    engine.shutdown()
    let database = workspace.userData.appendingPathComponent("tracer.userdb", isDirectory: true)
    try Data("this is not a leveldb manifest\n".utf8)
      .write(to: database.appendingPathComponent("CURRENT"))

    _ = try engine.start()
    // The database is opened when the schema loads, not when the engine starts: the session comes first,
    // and only then is there anything in the log to read.
    try engine.openSession()
    _ = try engine.processKeys("shurufa")
    let issues = engine.databaseIssues()
    let corruption = try XCTUnwrap(issues.first { $0.dictionary == "tracer" && !$0.isReadOnly },
                                   issues.map(\.message).joined(separator: " | "))
    XCTAssertTrue(corruption.message.contains("Corruption"), corruption.message)
    // Measured: the engine keeps running and the schema still types from the base dictionary, which is
    // exactly why the report has to be the place the event surfaces.
    let output = try engine.processKeys("shurufa")
    XCTAssertTrue(output.candidates.contains { $0.text == "输入法" },
                  output.candidates.map(\.text).joined(separator: ","))
    XCTAssertTrue(try engine.userDictionaryNames().contains("tracer"),
                  "librime still lists the database it rebuilt")

    let report = try RimeSyncService(workspace: workspace, engine: engine).report()
    let entry = try XCTUnwrap(report.dictionaries.first { $0.name == "tracer" })
    XCTAssertTrue(entry.isDamaged)
    XCTAssertTrue(entry.databaseIssues.contains { $0.message == corruption.message },
                  entry.databaseIssues.map(\.message).joined(separator: " | "))

    // What the user loses, and why the screen must not show "0 条" as if it were merely empty: the
    // rebuilt database has nothing to export.
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    let url = scratch.appendingPathComponent("after-corruption.txt")
    XCTAssertThrowsError(try access.perform { try engine.exportUserDictionary("tracer", to: url) })

    // The second failure comes with the first attempt to *use* the rebuilt database, which is what
    // tells the user the dictionary cannot be written either.
    XCTAssertTrue(engine.databaseIssues().contains { $0.dictionary == "tracer" && $0.isReadOnly },
                  engine.databaseIssues().map(\.message).joined(separator: " | "))
  }

  /// S5 §6's alternative transport: the user's folder is stored as a bookmark, validated when it
  /// changes, and seeded into `installation.yaml` — the file librime actually reads.
  func testAChosenSyncFolderIsStoredValidatedAndSeeded() throws {
    let folder = scratch.appendingPathComponent("picked-sync", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let choice = RimeSyncFolderChoice(path: folder.path, bookmark: Data("bookmark".utf8))
    XCTAssertEqual(try choice.validate().path, folder.path)

    let before = workspace.loadInstallation()?.installationID
    try workspace.saveSyncChoice(choice)
    XCTAssertEqual(workspace.loadSyncChoice(), choice, "the bookmark round-trips through the store")

    // "Validated whenever it changes": the three ways a folder can be unusable are named.
    XCTAssertThrowsError(try RimeSyncFolderChoice(path: "sync/relative", bookmark: Data()).validate()) { error in
      guard case RimeSyncFolderChoice.ValidationError.relativePath = error else {
        return XCTFail("expected relativePath, got \(error)")
      }
    }
    XCTAssertThrowsError(try RimeSyncFolderChoice(path: folder.appendingPathComponent("gone").path,
                                                  bookmark: Data()).validate()) { error in
      guard case RimeSyncFolderChoice.ValidationError.missing = error else {
        return XCTFail("expected missing, got \(error)")
      }
    }
    let file = scratch.appendingPathComponent("not-a-folder")
    try Data("x".utf8).write(to: file)
    XCTAssertThrowsError(try RimeSyncFolderChoice(path: file.path, bookmark: Data()).validate()) { error in
      guard case RimeSyncFolderChoice.ValidationError.notADirectory = error else {
        return XCTFail("expected notADirectory, got \(error)")
      }
    }

    let installation = try workspace.setSyncDirectory(try choice.validate())
    XCTAssertEqual(installation.syncDirectory, folder.path)
    XCTAssertEqual(workspace.loadInstallation()?.syncDirectory, folder.path)
    XCTAssertEqual(installation.installationID, before,
                   "the id is kept: two devices sharing one is what creates conflict copies")

    // Going back to the default is spelled by clearing the choice, not by writing a second one.
    try workspace.saveSyncChoice(nil)
    XCTAssertNil(workspace.loadSyncChoice())
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.syncChoiceFile.path))
  }

  /// S5 §5's second export: the whole set as one zip, in the sync folder's own shape.
  func testTheWholeSetExportsAsOneZipThatUnzipsIntoASyncFolder() async throws {
    try engine.openSession()
    _ = try engine.processKeys("shurufa")
    _ = try engine.selectCandidate(at: 0)
    engine.closeSession()

    let service = RimeSyncService(workspace: workspace, engine: engine)
    let export = try service.exportAllSnapshots()
    XCTAssertEqual(export.dictionaries, ["tracer"])
    XCTAssertGreaterThan(export.bytes, 0, "an empty zip would pass a weaker test")

    // Read it back with the reader that guards every import, then extract it: the paths are the sync
    // folder's own, so what comes out is a valid sync rather than a new format.
    let archive = try RimeZipArchive(data: export.data)
    let id = try XCTUnwrap(service.installationID)
    XCTAssertEqual(archive.entries.map(\.path), [id + "/tracer.userdb.txt"])

    let destination = scratch.appendingPathComponent("unzipped", isDirectory: true)
    try archive.extract(to: destination)
    let extracted = destination.appendingPathComponent(id)
      .appendingPathComponent("tracer.userdb.txt")
    let snapshot = try XCTUnwrap(RimeUserDictionarySnapshot.parse(
      text: try String(contentsOf: extracted, encoding: .utf8)))
    XCTAssertTrue(snapshot.entries.contains { $0.text == "输入法" },
                  snapshot.entries.map(\.text).joined(separator: ","))

    // And discovery reads exactly that shape, so a receiving device merges it like any other folder.
    XCTAssertEqual(RimeSyncDiscovery.snapshots(in: destination).map(\.dictionary), ["tracer"])
  }

  /// The spec's open `[verify]` in M5, answered — and the answer is **no**. `import_user_dict` reads the
  /// levers export format; handed the *sync snapshot* format (what Squirrel writes) it consumes the file and
  /// records the wrong thing: the entry that comes back is the spelling ("shu ru fa"), not the phrase
  /// ("输入法"). A Squirrel snapshot therefore has to be converted before it goes through this door, which is
  /// what the app does — it parses the snapshot with `RimeUserDictionarySnapshot` and imports the levers
  /// format it writes.
  ///
  /// The test asserts today's behaviour, so that a librime that learns to read the sync format changes this
  /// on purpose.
  func testTheSyncSnapshotFormatIsNotWhatImportUserDictReads() async throws {
    try engine.openSession()
    _ = try engine.processKeys("shurufa")
    _ = try engine.selectCandidate(at: 0)
    engine.closeSession()

    let service = RimeSyncService(workspace: workspace, engine: engine)
    let outcome = try service.syncNow()
    XCTAssertTrue(outcome.succeeded, outcome.failureReason ?? "")
    let device = try XCTUnwrap(service.deviceDirectory)
    let snapshotURL = device.appendingPathComponent("tracer.userdb.txt")
    XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path),
                  "the sync wrote a snapshot to import")

    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    XCTAssertTrue(try RimeDictionaryEditor(workspace: workspace, engine: engine)
      .removeDictionary("tracer"), "start from an empty dictionary so what imports is what arrives")
    _ = try access.perform { try engine.importUserDictionary("tracer", from: snapshotURL) }

    let exportURL = scratch.appendingPathComponent("after-snapshot-import.txt")
    _ = try access.perform { try engine.exportUserDictionary("tracer", to: exportURL) }
    let text = try String(contentsOf: exportURL, encoding: .utf8)
    let export = try XCTUnwrap(RimeUserDictionaryExport.parse(text: text))
    let texts = export.entries.map(\.text).joined(separator: ",")
    XCTAssertFalse(export.entries.contains { $0.text == "输入法" },
                   "it does not import as a phrase — if this starts passing, librime learned the format: " + texts)
    XCTAssertTrue(export.entries.contains { $0.text.trimmingCharacters(in: .whitespaces) == "shu ru fa" },
                  "it imports as the spelling instead: " + texts)
  }

  /// Discover user databases independently of installed profiles, excluding snapshots and other files.
  func testTheDatabaseScanListsDirectoriesAndNothingElse() throws {
    let userData = workspace.userData
    try FileManager.default.createDirectory(at: userData.appendingPathComponent("tracer.userdb",
                                                                        isDirectory: true),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: userData.appendingPathComponent("another.userdb",
                                                                        isDirectory: true),
                                            withIntermediateDirectories: true)
    try Data("notes".utf8).write(to: userData.appendingPathComponent("notes.txt"))
    try Data("snapshot".utf8).write(to: userData.appendingPathComponent("tracer.userdb.txt"))

    let service = RimeSyncService(workspace: workspace, engine: engine)
    XCTAssertEqual(service.discoveredDatabaseNames(), ["another", "tracer"])
  }
}
