import Foundation

// MARK: - JSON coding

/// One place for the on-disk formats, so `active.json` and `meta.json` cannot drift apart.
public enum RimeJSON {
  public static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return encoder
  }

  public static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  public static func encode<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
    try makeEncoder(pretty: pretty).encode(value)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try makeDecoder().decode(type, from: data)
  }
}

// MARK: - Installation record

/// `installation.yaml`. Seeded before the first engine start: librime writes a snapshot into a
/// `sync/` directory relative to the process's working directory when `sync_dir` is absent, which is
/// how a Squirrel sync silently lands somewhere nobody looks.
public struct RimeInstallation: Sendable, Hashable {
  public var installationID: String
  public var syncDirectory: String

  public init(installationID: String, syncDirectory: String) {
    self.installationID = installationID
    self.syncDirectory = syncDirectory
  }

  public var yaml: String {
    "installation_id: " + installationID + "\nsync_dir: " + syncDirectory + "\n"
  }

  public init?(yaml: String) {
    var identifier: String?
    var sync: String?
    for line in yaml.split(separator: "\n") {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      let key = parts[0].trimmingCharacters(in: .whitespaces)
      var value = parts[1].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      switch key {
      case "installation_id": identifier = value
      case "sync_dir": sync = value
      default: break
      }
    }
    guard let identifier, !identifier.isEmpty, let sync else { return nil }
    self.installationID = identifier
    self.syncDirectory = sync
  }
}

// MARK: - The chosen sync folder (S5 §6)

/// A sync folder the user picked, held as a bookmark so the app can reach it again after a relaunch,
/// and validated "whenever it changes": the path has to be absolute, present and a directory.
///
/// The bookmark itself is not resolved here — that is the platform's job, and the app is the side that
/// holds the security scope — so this type can be stored, compared and validated without a UI.
public struct RimeSyncFolderChoice: Codable, Sendable, Hashable {
  public let path: String
  public let bookmark: Data
  public let chosenAt: Date

  public init(path: String, bookmark: Data, chosenAt: Date = Date()) {
    self.path = path
    self.bookmark = bookmark
    self.chosenAt = chosenAt
  }

  public enum ValidationError: Error, CustomStringConvertible, Sendable {
    case relativePath(String)
    case missing(String)
    case notADirectory(String)

    public var description: String {
      switch self {
      case .relativePath(let path):
        return "the sync folder must be absolute, and " + path + " is not: librime accepts a "
          + "relative one silently and then writes a sync/ next to the process's working directory"
      case .missing(let path):
        return "the sync folder is not there any more: " + path
      case .notADirectory(let path):
        return "the sync folder is a file, not a directory: " + path
      }
    }
  }

  /// The folder as a URL, or the named reason it cannot be used.
  public func validate(fileManager: FileManager = .default) throws -> URL {
    guard path.hasPrefix("/") else { throw ValidationError.relativePath(path) }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
      throw ValidationError.missing(path)
    }
    guard isDirectory.boolValue else { throw ValidationError.notADirectory(path) }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
}

// MARK: - Workspace

/// `<app group>/rime/`: everything the app writes and the keyboard reads.
///
/// The bundle is never written to. The workspace is the only mutable root, and its layout is the
/// one S1 §3 fixes: profiles, a shared user directory, staging and logs.
public struct RimeWorkspace: Sendable {
  public let root: URL
  public let writableRoot: RimeDirectories.WritableRoot
  public let appGroupID: String?
  public let containerPath: String?

  public init(root: URL,
              writableRoot: RimeDirectories.WritableRoot = .custom,
              appGroupID: String? = nil,
              containerPath: String? = nil) {
    self.root = root
    self.writableRoot = writableRoot
    self.appGroupID = appGroupID
    self.containerPath = containerPath
  }

  /// Resolves the app group when the entitlement is present, and the process's own container when
  /// it is not. That difference is S1's degraded mode: the keyboard still reads a profile the app
  /// wrote, but it writes user state into its own container.
  public static func locate(appGroupID: String?, fileManager: FileManager = .default) -> RimeWorkspace {
    if let appGroupID,
       let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
      return RimeWorkspace(root: container.appendingPathComponent("rime", isDirectory: true),
                           writableRoot: .appGroup,
                           appGroupID: appGroupID,
                           containerPath: container.path)
    }
    let base = (try? fileManager.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true))
      ?? fileManager.temporaryDirectory
    return RimeWorkspace(root: base.appendingPathComponent("rime", isDirectory: true),
                         writableRoot: .container,
                         appGroupID: nil)
  }

  public var profilesRoot: URL { root.appendingPathComponent("profiles", isDirectory: true) }
  public var userData: URL { root.appendingPathComponent("user", isDirectory: true) }
  public var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
  public var log: URL { root.appendingPathComponent("log", isDirectory: true) }
  public var activeRecord: URL { root.appendingPathComponent("active.json") }
  /// Measured: librime reads `installation.yaml` from `user_data_dir`, not from the workspace root.
  /// With it anywhere else, `get_user_data_sync_dir()` returns a *relative* `sync/<id>` and the
  /// snapshots land relative to the process's working directory — the failure mode the spec warns
  /// about. It therefore lives in `user/`, which is the directory librime was handed.
  public var installationRecord: URL { userData.appendingPathComponent("installation.yaml") }
  public var patchesBackup: URL { root.appendingPathComponent("staging/patches", isDirectory: true) }

  public func profile(_ id: String) -> RimeProfileLayout {
    RimeProfileLayout(directory: profilesRoot.appendingPathComponent(id, isDirectory: true))
  }

  @discardableResult
  public func createDirectories(fileManager: FileManager = .default) throws -> RimeWorkspace {
    for directory in [root, profilesRoot, userData, staging, log] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return self
  }

  // MARK: Profiles

  public func profileIDs(fileManager: FileManager = .default) throws -> [String] {
    guard let contents = try? fileManager.contentsOfDirectory(atPath: profilesRoot.path) else {
      return []
    }
    return contents.filter { name in
      var isDirectory: ObjCBool = false
      let path = profilesRoot.appendingPathComponent(name).path
      return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }.sorted()
  }

  public func loadMetadata(for id: String, fileManager: FileManager = .default) throws -> RimeProfileMetadata? {
    let url = profile(id).metadata
    guard let data = try? Data(contentsOf: url) else { return nil }
    do {
      return try RimeJSON.decode(RimeProfileMetadata.self, from: data)
    } catch {
      throw RimeWorkspaceError.metadataUnreadable(id, String(describing: error))
    }
  }

  public func loadMetadataList(fileManager: FileManager = .default) throws -> [RimeProfileMetadata] {
    var result: [RimeProfileMetadata] = []
    for id in try profileIDs(fileManager: fileManager) {
      if let metadata = try loadMetadata(for: id, fileManager: fileManager) {
        result.append(metadata)
      } else {
        result.append(RimeProfileMetadata(id: id, displayName: id, source: RimeProfileSource(kind: .generated)))
      }
    }
    return result
  }

  public func writeMetadata(_ metadata: RimeProfileMetadata, fileManager: FileManager = .default) throws {
    let layout = profile(metadata.id)
    try fileManager.createDirectory(at: layout.directory, withIntermediateDirectories: true)
    try RimeJSON.encode(metadata).write(to: layout.metadata, options: .atomic)
  }

  // MARK: Active profile

  public func loadActiveProfile() throws -> RimeActiveProfile? {
    guard let data = try? Data(contentsOf: activeRecord) else { return nil }
    return try RimeJSON.decode(RimeActiveProfile.self, from: data)
  }

  public func writeActiveProfile(_ record: RimeActiveProfile) throws {
    try RimeJSON.encode(record).write(to: activeRecord, options: .atomic)
  }

  public func removeActiveProfile(fileManager: FileManager = .default) throws {
    if fileManager.fileExists(atPath: activeRecord.path) {
      try fileManager.removeItem(at: activeRecord)
    }
  }

  // MARK: Installation

  public func loadInstallation() -> RimeInstallation? {
    guard let text = try? String(contentsOf: installationRecord, encoding: .utf8) else { return nil }
    return RimeInstallation(yaml: text)
  }

  /// Where an `installation.yaml` that could not be read is moved before a fresh one is written. Its
  /// bytes are kept so the id can be recovered by hand; check whether the file exists after seeding.
  public var quarantinedInstallationURL: URL {
    installationRecord.appendingPathExtension("unreadable")
  }

  /// Writes `installation.yaml` if it is not there yet, and never rewrites an existing one: a
  /// second device sharing an `installation_id` is exactly what makes iCloud create conflict copies.
  ///
  /// A file that is there and does **not parse** is a different case, and it used to be handled the same
  /// way: `loadInstallation()` returned nil, this method wrote a fresh record, and the device silently
  /// minted a new `installation_id` — which moves its sync subdirectory, so its own earlier snapshots
  /// start looking like some other device's, and the next sync writes a second device directory. The
  /// unreadable file is moved aside with its bytes intact instead, and `quarantinedInstallationURL`
  /// names it so the caller can say that it happened.
  @discardableResult
  public func seedInstallation(syncDirectory: URL,
                               installationID: String = UUID().uuidString,
                               fileManager: FileManager = .default) throws -> RimeInstallation {
    if let existing = loadInstallation() { return existing }
    try createDirectories(fileManager: fileManager)
    if fileManager.fileExists(atPath: installationRecord.path) {
      let quarantine = quarantinedInstallationURL
      if fileManager.fileExists(atPath: quarantine.path) {
        try? fileManager.removeItem(at: quarantine)
      }
      try fileManager.moveItem(at: installationRecord, to: quarantine)
    }
    let record = RimeInstallation(installationID: installationID, syncDirectory: syncDirectory.path)
    try record.yaml.write(to: installationRecord, atomically: true, encoding: .utf8)
    return record
  }

  /// S5 §6's alternative transport: the user picked a sync folder. This is the one case where
  /// `installation.yaml` is rewritten, because the user asked for exactly that; the installation id is
  /// kept, since a second device sharing it is what creates conflict copies.
  @discardableResult
  public func setSyncDirectory(_ directory: URL,
                               fileManager: FileManager = .default) throws -> RimeInstallation {
    try createDirectories(fileManager: fileManager)
    let id = loadInstallation()?.installationID ?? UUID().uuidString
    let record = RimeInstallation(installationID: id, syncDirectory: directory.path)
    try record.yaml.write(to: installationRecord, atomically: true, encoding: .utf8)
    return record
  }

  // MARK: The chosen sync folder (S5 §6)

  /// Where the user's choice is kept. The bookmark is opaque here — the platform resolves it and the
  /// app holds the security scope — the engine only checks the path it names.
  public var syncChoiceFile: URL { root.appendingPathComponent("sync-choice.json") }

  public func loadSyncChoice() -> RimeSyncFolderChoice? {
    guard let data = try? Data(contentsOf: syncChoiceFile) else { return nil }
    return try? JSONDecoder().decode(RimeSyncFolderChoice.self, from: data)
  }

  /// Passing nil clears the choice, which is how "go back to the default (iCloud) folder" is spelled.
  public func saveSyncChoice(_ choice: RimeSyncFolderChoice?,
                             fileManager: FileManager = .default) throws {
    guard let choice else {
      if fileManager.fileExists(atPath: syncChoiceFile.path) {
        try fileManager.removeItem(at: syncChoiceFile)
      }
      return
    }
    try createDirectories(fileManager: fileManager)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(choice).write(to: syncChoiceFile, options: .atomic)
  }

  public var userSyncDirectory: URL {
    let id = loadInstallation()?.installationID ?? "unseeded"
    return userData.appendingPathComponent("sync", isDirectory: true)
      .appendingPathComponent(id, isDirectory: true)
  }

  // MARK: Storage

  public func storageReport(fileManager: FileManager = .default) throws -> RimeStorageReport {
    var entries: [RimeStorageReport.ProfileEntry] = []
    for id in try profileIDs(fileManager: fileManager) {
      let layout = profile(id)
      let metadata = try loadMetadata(for: id, fileManager: fileManager)
      entries.append(RimeStorageReport.ProfileEntry(
        id: id,
        displayName: metadata?.displayName ?? id,
        sourceBytes: RimeWorkspace.directorySize(layout.source),
        buildBytes: RimeWorkspace.directorySize(layout.build),
        previousBuildBytes: RimeWorkspace.directorySize(layout.buildPrevious),
        generation: metadata?.deploy?.generation,
        schemaCount: metadata?.stats.schemaIDs.count ?? 0,
        license: metadata?.license?.spdx))
    }
    return RimeStorageReport(profiles: entries,
                             userDataBytes: RimeWorkspace.directorySize(userData),
                             stagingBytes: RimeWorkspace.directorySize(staging))
  }

  public static func directorySize(_ url: URL, fileManager: FileManager = .default) -> Int {
    guard let enumerator = fileManager.enumerator(at: url,
                                                  includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                  options: [.skipsHiddenFiles]) else { return 0 }
    var total = 0
    for case let item as URL in enumerator {
      let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values?.isRegularFile == true {
        total += values?.fileSize ?? 0
      }
    }
    return total
  }

  // MARK: Deletion and policy

  /// Removes a profile. The user dictionaries it produced are shared by dictionary name and live
  /// in `user/`, so they are only removed when the user asks for that explicitly (§7).
  public func deleteProfile(_ id: String,
                            removingUserDictionaries dictionaryNames: [String] = [],
                            fileManager: FileManager = .default) throws {
    let layout = profile(id)
    let wasActive = try loadActiveProfile()?.profileID == id
    if fileManager.fileExists(atPath: layout.directory.path) {
      try fileManager.removeItem(at: layout.directory)
    }
    // Clear activation before optional dictionary cleanup, which can fail independently.
    if wasActive { try removeActiveProfile(fileManager: fileManager) }
    for name in dictionaryNames {
      let database = userData.appendingPathComponent(name + ".userdb", isDirectory: true)
      if fileManager.fileExists(atPath: database.path) {
        try fileManager.removeItem(at: database)
      }
    }
  }

  /// S1 §3: the workspace must be readable before the first unlock of a boot, and derived
  /// hundreds-of-megabytes artifacts must not inflate an iCloud backup.
  public func applyStoragePolicy(fileManager: FileManager = .default) throws {
    #if os(iOS)
    try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                   ofItemAtPath: root.path)
    #endif
    var excluded: [URL] = [staging]
    for id in try profileIDs(fileManager: fileManager) {
      let layout = profile(id)
      excluded.append(layout.build)
      excluded.append(layout.buildPrevious)
      excluded.append(layout.buildStaging)
    }
    for url in excluded where fileManager.fileExists(atPath: url.path) {
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutable = url
      try? mutable.setResourceValues(values)
    }
  }
}

public enum RimeWorkspaceError: Error, CustomStringConvertible, Sendable {
  case metadataUnreadable(String, String)

  public var description: String {
    switch self {
    case .metadataUnreadable(let id, let reason):
      return "meta.json for profile '" + id + "' could not be read: " + reason
    }
  }
}

public struct RimeStorageReport: Sendable, Equatable {
  public struct ProfileEntry: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let sourceBytes: Int
    public let buildBytes: Int
    public let previousBuildBytes: Int
    public let generation: Int?
    public let schemaCount: Int
    public let license: String?
  }

  public var profiles: [ProfileEntry]
  public var userDataBytes: Int
  public var stagingBytes: Int

  public var totalBytes: Int {
    profiles.reduce(userDataBytes + stagingBytes) { $0 + $1.sourceBytes + $1.buildBytes + $1.previousBuildBytes }
  }
}

// MARK: - Janitor

/// Launch-time repair (§3): staging is scratch and always goes, a killed deploy's
/// `build.staging` goes, and a profile whose build is missing but whose previous generation
/// survived is restored rather than left untypeable.
public struct RimeWorkspaceJanitor: Sendable {
  public struct Outcome: Sendable, Equatable {
    public var removedStagingEntries: [String] = []
    public var removedBuildStaging: [String] = []
    public var restoredBuilds: [String] = []
    public var notes: [String] = []

    public init() {}
  }

  public init() {}

  @discardableResult
  public func run(workspace: RimeWorkspace, fileManager: FileManager = .default) -> Outcome {
    var outcome = Outcome()

    if let entries = try? fileManager.contentsOfDirectory(atPath: workspace.staging.path) {
      for entry in entries {
        let url = workspace.staging.appendingPathComponent(entry)
        if (try? fileManager.removeItem(at: url)) != nil {
          outcome.removedStagingEntries.append(entry)
        }
      }
    }

    let ids = (try? workspace.profileIDs(fileManager: fileManager)) ?? []
    for id in ids {
      let layout = workspace.profile(id)

      if fileManager.fileExists(atPath: layout.buildStaging.path) {
        if (try? fileManager.removeItem(at: layout.buildStaging)) != nil {
          outcome.removedBuildStaging.append(id)
        }
      }

      let hasBuild = fileManager.fileExists(atPath: layout.build.path)
      let hasPrevious = fileManager.fileExists(atPath: layout.buildPrevious.path)
      if !hasBuild && hasPrevious {
        do {
          try fileManager.moveItem(at: layout.buildPrevious, to: layout.build)
          outcome.restoredBuilds.append(id)
          outcome.notes.append("restored build.previous for " + id)
        } catch {
          outcome.notes.append("could not restore " + id + ": " + String(describing: error))
        }
      }
    }
    return outcome
  }
}

// MARK: - Resolution

/// Which directories this process should bind the engine to, and why.
public struct RimeResolvedProfile: Sendable, Equatable {
  public enum Origin: String, Sendable {
    case appGroup
    case container
    case bundled
  }

  public let origin: Origin
  public let profileID: String?
  public let generation: Int?
  public let buildDirectory: URL
  public let directories: RimeDirectories
  /// Why the bundled data is in use, when it is. Nil when a profile was resolved.
  public let fallbackReason: String?

  public var isDegraded: Bool { origin == .bundled }
}

/// The extension's whole configuration path: read `active.json`, resolve the profile, fall back to
/// the bundle, and say which of the three states is in effect.
public enum RimeWorkspaceResolver {
  public static func resolve(workspace: RimeWorkspace,
                             bundledSharedData: URL,
                             appGroupAvailable: Bool = true,
                             fileManager: FileManager = .default) -> RimeResolvedProfile {
    let fallback = bundled(workspace: workspace, bundledSharedData: bundledSharedData)

    guard appGroupAvailable else {
      return RimeResolvedProfile(origin: .bundled, profileID: nil, generation: nil,
                                 buildDirectory: bundledSharedData,
                                 directories: fallback,
                                 fallbackReason: "the app group is unreachable")
    }

    let active: RimeActiveProfile
    do {
      guard let loaded = try workspace.loadActiveProfile() else {
        return RimeResolvedProfile(origin: .bundled, profileID: nil, generation: nil,
                                   buildDirectory: bundledSharedData, directories: fallback,
                                   fallbackReason: "no active.json")
      }
      active = loaded
    } catch {
      return RimeResolvedProfile(origin: .bundled, profileID: nil, generation: nil,
                                 buildDirectory: bundledSharedData, directories: fallback,
                                 fallbackReason: "active.json is unreadable: " + String(describing: error))
    }

    guard active.isCompatible else {
      return RimeResolvedProfile(origin: .bundled, profileID: nil, generation: nil,
                                 buildDirectory: bundledSharedData, directories: fallback,
                                 fallbackReason: "active.json schemaVersion " + String(active.schemaVersion)
                                   + " is newer than this build understands")
    }

    // Compiled tables from a different librime version cannot be bound safely, including
    // build.previous. Reject the pointer before considering either build directory.
    guard active.engineVersion == RimeEngineVersion.pinned else {
      return RimeResolvedProfile(origin: .bundled, profileID: nil, generation: nil,
                                 buildDirectory: bundledSharedData, directories: fallback,
                                 fallbackReason: "active.json engineVersion " + active.engineVersion
                                   + " is incompatible with this engine " + RimeEngineVersion.pinned)
    }

    let layout = workspace.profile(active.profileID)
    let origin: RimeResolvedProfile.Origin = workspace.writableRoot == .appGroup ? .appGroup : .container

    if layout.buildIsUsable(layout.build) {
      return RimeResolvedProfile(origin: origin, profileID: active.profileID, generation: active.generation,
                                 buildDirectory: layout.build,
                                 directories: client(workspace: workspace, layout: layout, build: layout.build),
                                 fallbackReason: nil)
    }

    if layout.buildIsUsable(layout.buildPrevious) {
      return RimeResolvedProfile(origin: origin, profileID: active.profileID, generation: active.generation,
                                 buildDirectory: layout.buildPrevious,
                                 directories: client(workspace: workspace, layout: layout, build: layout.buildPrevious),
                                 fallbackReason: "the active build is missing or empty; using build.previous")
    }

    return RimeResolvedProfile(origin: .bundled, profileID: nil, generation: nil,
                               buildDirectory: bundledSharedData, directories: fallback,
                               fallbackReason: "profile '" + active.profileID + "' has no usable build")
  }

  static func bundled(workspace: RimeWorkspace, bundledSharedData: URL) -> RimeDirectories {
    let bundledBuild = bundledSharedData.appendingPathComponent("build", isDirectory: true)
    let prebuilt = FileManager.default.fileExists(atPath: bundledBuild.path) ? bundledBuild : workspace.staging
    return RimeDirectories(sharedDataDir: bundledSharedData.path,
                           prebuiltDataDir: prebuilt.path,
                           userDataDir: workspace.userData.path,
                           stagingDir: workspace.staging.path,
                           logDir: workspace.log.path,
                           writableRoot: workspace.writableRoot,
                           appGroupID: workspace.appGroupID,
                           containerPath: workspace.containerPath)
  }

  static func client(workspace: RimeWorkspace, layout: RimeProfileLayout, build: URL) -> RimeDirectories {
    RimeDirectories(sharedDataDir: layout.source.path,
                    prebuiltDataDir: build.path,
                    userDataDir: workspace.userData.path,
                    // librime searches staging before prebuilt for compiled schemas. A failed
                    // deploy must never shadow the published generation with partial output.
                    stagingDir: build.path,
                    logDir: workspace.log.path,
                    writableRoot: workspace.writableRoot,
                    appGroupID: workspace.appGroupID,
                    containerPath: workspace.containerPath)
  }
}

// MARK: - Bindings

public enum RimeBindings {
  /// What the keyboard and the app's preview bind to: the profile's source, its deployed build,
  /// the shared user directory, and the published build for both runtime lookup paths.
  public static func client(workspace: RimeWorkspace, profileID: String, buildDirectory: URL) -> RimeDirectories {
    RimeWorkspaceResolver.client(workspace: workspace,
                                 layout: workspace.profile(profileID),
                                 build: buildDirectory)
  }

  /// What the deployer binds to (§6): the profile's source, and `build.staging` as both the
  /// prebuilt directory and the staging directory, so librime writes the tables where the client
  /// will read them after the swap.
  public static func deployer(workspace: RimeWorkspace, profileID: String) -> RimeDirectories {
    let layout = workspace.profile(profileID)
    return RimeDirectories(sharedDataDir: layout.source.path,
                           prebuiltDataDir: layout.buildStaging.path,
                           userDataDir: workspace.userData.path,
                           stagingDir: layout.buildStaging.path,
                           logDir: workspace.log.path,
                           writableRoot: workspace.writableRoot,
                           appGroupID: workspace.appGroupID,
                           containerPath: workspace.containerPath)
  }
}
