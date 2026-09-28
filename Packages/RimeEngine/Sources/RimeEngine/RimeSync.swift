import Foundation

// MARK: - Engine: restore

extension RimeEngine {
  /// librime's own restore from a snapshot file. The file carries its dictionary name in its
  /// `#@/db_name` header, which is why the call takes only a path.
  @discardableResult
  public func restoreUserDictionary(snapshotFile: URL) throws -> Bool {
    try perform {
      guard isStarted else { throw RimeUserDictionaryError.engineNotStarted }
      guard let levers = RimeLevers.pointer, let restore = levers.pointee.restore_user_dict else {
        throw RimeUserDictionaryError.leversUnavailable
      }
      guard FileManager.default.fileExists(atPath: snapshotFile.path) else {
        throw RimeUserDictionaryError.fileMissing(snapshotFile.path)
      }
      let box = CStringBox(snapshotFile.path)
      return restore(box.raw)
    }
  }
}

// MARK: - Report

/// What the 用户词库 screen shows: one row per dictionary, the snapshots that exist for it, and
/// where the sync folder is.
public struct RimeUserDictionaryReport: Sendable {
  public struct Entry: Sendable, Hashable {
    public let name: String
    public let databaseBytes: Int
    /// Snapshot bytes written by this device's installation id.
    public let localSnapshotBytes: Int
    /// Snapshots written by other devices, which is what a merge would read.
    public let otherDeviceIDs: [String]
    public let conflictCopies: Int
    public let entryCount: Int
    public let modifiedAt: Date?

    public var isLearned: Bool { databaseBytes > 0 }
  }

  public let dictionaries: [Entry]
  public let syncDirectory: String?
  public let installationID: String?
  public let userID: String?
  /// False while the keyboard holds the lease: the screen then says why it cannot act.
  public let isLeaseCold: Bool

  public var totalBytes: Int { dictionaries.reduce(0) { $0 + $1.databaseBytes } }
}

public struct RimeSyncOutcome: Sendable {
  public let succeeded: Bool
  public let duration: TimeInterval
  public let failureReason: String?
  public let notifications: [RimeNotification]
  public let snapshots: [RimeSyncSnapshot]
  public let snapshotDirectory: URL?
  public let logs: [RimeLogRecord]

  public var snapshotCount: Int { snapshots.count }
}

public enum RimeSyncError: Error, CustomStringConvertible, Sendable {
  case noSyncDirectory
  case refused(String)
  case timedOut(TimeInterval)
  case notASnapshot(String)

  public var description: String {
    switch self {
    case .noSyncDirectory:
      return "installation.yaml has no absolute sync_dir, so librime would write the snapshot "
        + "somewhere nobody looks"
    case .refused(let reason):
      return reason
    case .timedOut(let seconds):
      return "the sync did not finish within " + String(format: "%.0f", seconds) + " s"
    case .notASnapshot(let path):
      return "the file is not a Rime user dictionary snapshot: " + path
    }
  }
}

// MARK: - Service

/// S5's transport, minus the iCloud plumbing: it runs librime's own sync — the call Squirrel's
/// 同步用户数据 menu makes — and reads the folder both sides can see.
public struct RimeSyncService {
  public let workspace: RimeWorkspace
  public let engine: RimeEngine
  private let fileManager: FileManager

  public init(workspace: RimeWorkspace, engine: RimeEngine, fileManager: FileManager = .default) {
    self.workspace = workspace
    self.engine = engine
    self.fileManager = fileManager
  }

  public var installationID: String? { workspace.loadInstallation()?.installationID }

  /// The user's sync folder, as an absolute path. S1 seeds it before the first engine start,
  /// because librime accepts a relative `sync_dir` silently and then writes a `sync/` directory
  /// relative to the process's working directory.
  public var syncDirectory: URL? {
    guard let installation = workspace.loadInstallation(),
          installation.syncDirectory.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: installation.syncDirectory, isDirectory: true)
  }

  /// The directory this device writes into.
  public var deviceDirectory: URL? {
    guard let syncDirectory, let installationID else { return nil }
    return syncDirectory.appendingPathComponent(installationID, isDirectory: true)
  }

  // MARK: Reading

  public func report(now: Date = Date()) throws -> RimeUserDictionaryReport {
    let names = (try? engine.userDictionaryNames()) ?? []
    let databaseNames = discoveredDatabaseNames()
    let syncDirectory = self.syncDirectory
    let installationID = self.installationID
    let snapshots = syncDirectory.map { RimeSyncDiscovery.snapshots(in: $0, fileManager: fileManager) } ?? []
    // A dictionary can exist only as a snapshot — a fresh install that has not synced yet — and the
    // screen still has to list it.
    let snapshotNames = snapshots.map(\.dictionary)
    let allNames = Array(Set(names + databaseNames + snapshotNames)).sorted()

    var entries: [RimeUserDictionaryReport.Entry] = []
    for name in allNames {
      let database = workspace.userData.appendingPathComponent(name + ".userdb", isDirectory: true)
      let mine = snapshots.filter { $0.dictionary == name && $0.deviceID == installationID }
      let others = snapshots.filter { $0.dictionary == name && $0.deviceID != installationID }
      let entryCount = mine.sorted { $0.modifiedAt > $1.modifiedAt }.first?.entryCount
        ?? others.first?.entryCount ?? 0
      // Broken into steps: as one expression this was more than the type checker would take on.
      let databaseBytes = RimeWorkspace.directorySize(database, fileManager: fileManager)
      let localSnapshotBytes = mine.reduce(0) { $0 + $1.bytes }
      let otherDeviceIDs = Array(Set(others.map(\.deviceID))).sorted()
      let conflicts = snapshots.filter { $0.dictionary == name && $0.isConflictCopy }.count
      let modified = try? database.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      entries.append(RimeUserDictionaryReport.Entry(name: name,
                                                    databaseBytes: databaseBytes,
                                                    localSnapshotBytes: localSnapshotBytes,
                                                    otherDeviceIDs: otherDeviceIDs,
                                                    conflictCopies: conflicts,
                                                    entryCount: entryCount,
                                                    modifiedAt: modified))
    }

    return RimeUserDictionaryReport(dictionaries: entries,
                                    syncDirectory: syncDirectory?.path,
                                    installationID: installationID,
                                    userID: engine.userID(),
                                    isLeaseCold: RimeLeaseStore(workspace: workspace).isCold(now: now))
  }

  /// Dictionaries the filesystem knows about even when librime has not loaded them: a profile the
  /// user deleted can leave a `.userdb` behind, and the screen has to show it to offer deleting it.
  public func discoveredDatabaseNames() -> [String] {
    let contents = (try? fileManager.contentsOfDirectory(atPath: workspace.userData.path)) ?? []
    return contents.filter { $0.hasSuffix(".userdb") }
      .map { String($0.dropLast(".userdb".count)) }
      .sorted()
  }

  // MARK: Syncing

  /// Writes this device's snapshots into the sync folder — the files Squirrel's own sync reads.
  ///
  /// Measured on the pinned build, and it shapes the implementation: `sync_user_data()` returns
  /// false and writes nothing, with or without a session open and with the sync directory empty,
  /// so it cannot be the thing this depends on. The primitive that does write the file is
  /// `backup_user_dict(name)` — the same file, the same format — and it needs the session closed,
  /// because the leveldb user dictionary is locked while one is open. `sync_user_data()` is still
  /// called, best-effort, for the per-device YAML copies it would otherwise add.
  @discardableResult
  public func syncNow() throws -> RimeSyncOutcome {
    guard let syncDirectory else { throw RimeSyncError.noSyncDirectory }
    try fileManager.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    if let holder = access.blocker() {
      throw RimeSyncError.refused(RimeDictionaryAccessError
        .keyboardIsUsingIt(pid: holder.pid, since: holder.openedAt).description)
    }

    let started = Date()
    engine.clearNotifications()
    let hadSession = engine.isSessionOpen
    let names = try dictionariesToSync()
    var backedUp: [String] = []
    var refused: [String] = []

    try access.perform {
      for name in names {
        // S5 §4: the snapshot about to be overwritten is archived first, so a sync that brings in
        // something unwanted can be undone from beside the snapshot rather than from a folder the
        // user never sees.
        _ = try? backup(dictionary: name, now: started)
        if (try? engine.backupUserDictionary(name)) == true {
          backedUp.append(name)
        } else {
          refused.append(name)
        }
      }
    }
    // Best effort: librime's own sync, for the YAML config copies that travel beside the
    // dictionaries. Its result is recorded, never depended on.
    let scheduled = (try? engine.syncUserData()) ?? false
    engine.joinMaintenance()
    // Measured: running librime's maintenance drops the session it was holding, so the caller's
    // session is restored here rather than left for the next keystroke to discover as missing.
    if hadSession, !engine.isSessionOpen {
      try? engine.openSession()
    }

    var failure: String?
    if !names.isEmpty, backedUp.isEmpty {
      failure = "librime refused every user dictionary: " + refused.joined(separator: ", ")
    }

    // The directory librime itself resolved: after the installation.yaml fix it is absolute, and
    // comparing it against ours is how a mis-seeded sync folder is caught instead of guessed at.
    let resolved = engine.userDataSyncDirectory()
    let resolvedDirectory = resolved.map { URL(fileURLWithPath: $0, isDirectory: true) }

    var notes = engine.notifications()
    if scheduled { notes.append(.other(type: "sync", value: "librime reported the sync as scheduled")) }
    return RimeSyncOutcome(succeeded: failure == nil,
                           duration: Date().timeIntervalSince(started),
                           failureReason: failure,
                           notifications: notes,
                           snapshots: snapshots(),
                           snapshotDirectory: resolvedDirectory ?? deviceDirectory,
                           logs: engine.logBuffer.snapshot())
  }

  /// The dictionaries worth snapshotting: what librime has loaded, plus any `.userdb` directory
  /// the filesystem knows about (a profile the user deleted leaves one behind).
  public func dictionariesToSync() throws -> [String] {
    let loaded = (try? engine.userDictionaryNames()) ?? []
    return Array(Set(loaded + discoveredDatabaseNames())).sorted()
  }

  public func snapshots() -> [RimeSyncSnapshot] {
    guard let syncDirectory else { return [] }
    return RimeSyncDiscovery.snapshots(in: syncDirectory, fileManager: fileManager)
  }

  // MARK: Explicit file paths

  /// Imports one snapshot the user picked. A backup of the current dictionary is taken first, so a
  /// merge that brings in something unwanted can be undone.
  @discardableResult
  public func importSnapshot(at url: URL) throws -> RimeUserDictionarySnapshot {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let snapshot = RimeUserDictionarySnapshot.parse(text: text) else {
      throw RimeSyncError.notASnapshot(url.path)
    }
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    try access.requireExclusiveAccess()
    if let name = snapshot.dictionary {
      _ = try? backup(dictionary: name)
    }
    _ = try engine.restoreUserDictionary(snapshotFile: url)
    return snapshot
  }

  /// S5 §4's backup: `<dict>.userdb.<timestamp>.txt`, **beside** this device's snapshots and
  /// pruned to the last three per dictionary. Written before every import or sync, so the state the
  /// change is about to replace is the one the file holds.
  ///
  /// The copy keeps the *snapshot* format — the same bytes `backup_user_dict` writes — because
  /// that is what `restore_user_dict` reads back. The levers export format is a different door
  /// (S5 §5, measured), and quietly writing one into a file named like the other would make a restore
  /// unreadable at the worst moment.
  @discardableResult
  public func backup(dictionary: String, now: Date = Date(), keeping: Int = 3) throws -> URL? {
    guard let deviceDirectory else { return nil }
    let live = deviceDirectory.appendingPathComponent(dictionary + ".userdb.txt")
    if !fileManager.fileExists(atPath: live.path) {
      // The sync folder has never seen this dictionary. Write the current state first: it is exactly
      // the state the caller is about to change.
      guard (try? engine.backupUserDictionary(dictionary)) == true else { return nil }
    }
    guard fileManager.fileExists(atPath: live.path) else { return nil }
    try fileManager.createDirectory(at: deviceDirectory, withIntermediateDirectories: true)
    let target = deviceDirectory
      .appendingPathComponent(dictionary + ".userdb." + stamp(now) + ".txt")
    if fileManager.fileExists(atPath: target.path) {
      try fileManager.removeItem(at: target)
    }
    try fileManager.copyItem(at: live, to: target)
    try pruneBackups(dictionary: dictionary, keeping: keeping)
    return target
  }

  /// This device's backups for one dictionary, newest first. The live snapshot is not one of them.
  public func backups(for dictionary: String) -> [URL] {
    guard let deviceDirectory else { return [] }
    let liveName = dictionary + ".userdb.txt"
    let prefix = dictionary + ".userdb."
    let contents = (try? fileManager.contentsOfDirectory(
      at: deviceDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return contents
      .filter { $0.lastPathComponent.hasPrefix(prefix)
                && $0.lastPathComponent != liveName
                && $0.pathExtension == "txt" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  /// Keeps the newest `keeping` backups for one dictionary and returns the ones it removed.
  @discardableResult
  public func pruneBackups(dictionary: String, keeping: Int = 3) throws -> [URL] {
    let all = backups(for: dictionary)
    guard all.count > keeping else { return [] }
    let doomed = Array(all.dropFirst(keeping))
    for url in doomed {
      try fileManager.removeItem(at: url)
    }
    return doomed
  }

  /// The timestamp in a backup's file name. ISO 8601 with colons replaced, so the names sort the way
  /// the times do — a folder listing needs no parsing to be in order.
  private func stamp(_ now: Date) -> String {
    ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
  }

  /// The levers export, for the user's own file: a shape Squirrel does **not** read, which is why
  /// the UI names which of the two it is writing.
  @discardableResult
  public func exportDictionary(_ name: String, to url: URL) throws -> Int {
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    return try access.perform { try engine.exportUserDictionary(name, to: url) }
  }

  @discardableResult
  public func importExportFile(_ url: URL, into name: String) throws -> Int {
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
    return try access.perform { try engine.importUserDictionary(name, from: url) }
  }
}
