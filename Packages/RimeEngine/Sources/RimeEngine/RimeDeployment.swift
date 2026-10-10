import Foundation

// MARK: - Outcomes

public struct RimeDeploymentOutcome: Sendable {
  public let profileID: String
  public let generation: Int
  public let report: RimeDeploymentReport
  public let metadata: RimeProfileMetadata
  public let active: RimeActiveProfile

  public var durationSeconds: Double { report.duration }
  public var buildBytes: Int { report.totalBytes }
}

public enum RimeDeploymentFailure: Error, CustomStringConvertible, Sendable {
  case profileNotFound(String)
  case noSources(String)
  case deployFailed(RimeDeploymentReport)
  case buildUnusable(String)
  case rollbackUnavailable(String)
  case activationFailed(String)
  case recoveryFailed(original: String, recovery: String)

  public var description: String {
    switch self {
    case .profileNotFound(let id):
      return "there is no profile '" + id + "' in the workspace"
    case .noSources(let path):
      return "the profile has no sources at " + path
    case .deployFailed(let report):
      let reason = report.failureReason ?? "librime reported a deploy failure"
      if let last = report.logs.last(where: { $0.severity >= .error }) {
        return reason + " — " + last.display
      }
      return reason
    case .buildUnusable(let id):
      return "profile '" + id + "' has no usable build to activate"
    case .rollbackUnavailable(let id):
      return "profile '" + id + "' has no previous generation to roll back to"
    case .recoveryFailed(let original, let recovery):
      return original + "; deployment recovery failed: " + recovery
    case .activationFailed(let reason):
      return "the profile could not be activated: " + reason
    }
  }
}

// MARK: - Coordinator

/// The app-side half of S1 §6: deploy into `build.staging`, swap atomically, point
/// `active.json` at the result, and keep one generation for rollback.
///
/// Runs in the app only. The extension never deploys: librime's maintenance takes tens of seconds on
/// a real config, which is longer than a keyboard extension is allowed to live, and it would hold
/// the user's session while it ran.
/// `@unchecked Sendable` like the lease store: a stateless handle over the workspace and the engine,
/// plus the same injectable `FileManager`. Its async form hops to a background queue, so the value has
/// to cross that boundary.
public struct RimeDeploymentCoordinator: @unchecked Sendable {
  public let workspace: RimeWorkspace
  public let engine: RimeEngine
  private let fileManager: FileManager

  public init(workspace: RimeWorkspace, engine: RimeEngine, fileManager: FileManager = .default) {
    self.workspace = workspace
    self.engine = engine
    self.fileManager = fileManager
  }

  // MARK: Deploy

  /// The blocking form. The app calls `deploy(profileID:fullCheck:progress:)`; the tests call this.
  @discardableResult
  public func deploySync(profileID: String,
                         fullCheck: Bool = true,
                         activate: Bool = true,
                         progress: (@Sendable (RimeDeploymentProgress) -> Void)? = nil)
    throws -> RimeDeploymentOutcome {
    try engine.perform {
      try engine.withDictionaryOwnership(store: engine.dictionaryLeaseStore, host: engine.dictionaryHost) {
        try deployLocked(profileID: profileID, fullCheck: fullCheck, activate: activate, progress: progress)
      }
    }
  }

  private func deployLocked(profileID: String, fullCheck: Bool, activate: Bool,
                            progress: (@Sendable (RimeDeploymentProgress) -> Void)?) throws -> RimeDeploymentOutcome {
    let layout = workspace.profile(profileID)
    guard fileManager.fileExists(atPath: layout.directory.path) else {
      throw RimeDeploymentFailure.profileNotFound(profileID)
    }
    guard fileManager.fileExists(atPath: layout.source.path) else {
      throw RimeDeploymentFailure.noSources(layout.source.path)
    }

    // A previous attempt's staging directory is not a generation: it is what a killed deploy left.
    if fileManager.fileExists(atPath: layout.buildStaging.path) {
      try? fileManager.removeItem(at: layout.buildStaging)
    }
    try fileManager.createDirectory(at: layout.buildStaging, withIntermediateDirectories: true)

    // Measured, and it was a bug: librime's deployer only writes what it decides to rebuild, so a
    // staging directory that starts **empty** produces a generation containing just the YAML it
    // copied — the compiled tables from the previous deploy are gone, and the keyboard is left with
    // no dictionary at all. The previous build is therefore seeded into staging first, by copy. Staging must own its inodes so even an in-place
    // compiler write cannot alter the published generation during a failed deploy.
    if fileManager.fileExists(atPath: layout.build.path) {
      try seedStaging(from: layout.build, into: layout.buildStaging)
    }

    let runtime = try engine.captureRuntime()
    try RimeCustomPhraseFile.connectToSchemas(in: layout.source, workspace: workspace, engine: engine)
    let metadataBefore = fileManager.fileExists(atPath: layout.metadata.path)
      ? try Data(contentsOf: layout.metadata) : nil
    let activeBefore = fileManager.fileExists(atPath: workspace.activeRecord.path)
      ? try Data(contentsOf: workspace.activeRecord) : nil
    // Keep the older rollback generation until every publication step has succeeded.
    let previousBackup = workspace.staging.appendingPathComponent("deploy-" + UUID().uuidString)
    var savedPrevious = false
    var movedBuild = false
    var publishedBuild = false
    var wroteMetadata = false
    var wroteActive = false
    do {
      let directories = RimeBindings.deployer(workspace: workspace, profileID: profileID)
      let report: RimeDeploymentReport
      do {
        report = try engine.deploySync(binding: directories, fullCheck: fullCheck) { update in
          // Maintenance success is provisional until publication and runtime binding succeed.
          if update.phase != .succeeded { progress?(update) }
        }
      } catch let error as RimeDeploymentError {
        throw RimeDeploymentFailure.deployFailed(error.report)
      }

      // Success: swap, then point active.json at the result. Three renames inside one volume, in the
      // order S1 §3 fixes, so a crash between them is recoverable by the launch janitor.
      let generation = (try workspace.loadMetadata(for: profileID))?.deploy?.generation ?? 0
      let nextGeneration = generation + 1
      do {
        if fileManager.fileExists(atPath: layout.buildPrevious.path) {
          try fileManager.moveItem(at: layout.buildPrevious, to: previousBackup)
          savedPrevious = true
        }
        if fileManager.fileExists(atPath: layout.build.path) {
          try fileManager.moveItem(at: layout.build, to: layout.buildPrevious)
          movedBuild = true
        }
        try fileManager.moveItem(at: layout.buildStaging, to: layout.build)
        publishedBuild = true
      } catch {
        throw RimeDeploymentFailure.activationFailed(String(describing: error))
      }

      let digest = RimeDigest.sha256(ofTree: layout.source, fileManager: fileManager)
      var metadata = (try? workspace.loadMetadata(for: profileID))
        ?? RimeProfileMetadata(id: profileID, displayName: profileID, source: RimeProfileSource(kind: .generated))
      let warnings = report.logs.filter { $0.severity >= .warning }.map(\.display)
      metadata.stats.buildBytes = report.totalBytes
      metadata.stats.sourceBytes = RimeWorkspace.directorySize(layout.source)
      // get_schema_list() is populated by the switcher, which needs a live session; a deploy has
      // none. Only replace the imported list when the engine actually knows one, so a deploy cannot
      // erase the schema ids the import recorded.
      let deployedSchemas = (try? engine.schemaIDs()) ?? []
      if !deployedSchemas.isEmpty {
        metadata.stats.schemaIDs = deployedSchemas
      }
      metadata.deploy = RimeProfileDeployRecord(generation: nextGeneration,
                                                deployedAt: Date(),
                                                engineVersion: RimeEngineVersion.pinned,
                                                durationSeconds: report.duration,
                                                warnings: warnings)
      wroteMetadata = true
      try workspace.writeMetadata(metadata, fileManager: fileManager)
      try workspace.applyStoragePolicy(fileManager: fileManager)

      var active = RimeActiveProfile(profileID: profileID,
                                     generation: nextGeneration,
                                     engineVersion: RimeEngineVersion.pinned,
                                     sourceDigest: digest)
      if activate {
        let previous = try? workspace.loadActiveProfile()
        if let previous, previous.profileID != profileID {
          active.previousProfileID = previous.profileID
        }
        wroteActive = true
        try workspace.writeActiveProfile(active)
      }
      // The app's own engine follows immediately; the keyboard adopts at its next appearance (§8).
      if activate {
        _ = try engine.rebind(to: RimeBindings.client(workspace: workspace, profileID: profileID,
                                                      buildDirectory: layout.build))
        if runtime.hadSession { try engine.openSession() }
      } else {
        try engine.restoreRuntime(runtime)
      }
      if savedPrevious { try? fileManager.removeItem(at: previousBackup) }
      progress?(RimeDeploymentProgress(phase: .succeeded,
                                       message: "profile " + profileID + " generation "
                                         + String(nextGeneration)))
      return RimeDeploymentOutcome(profileID: profileID, generation: nextGeneration, report: report,
                                   metadata: metadata, active: active)
    } catch {
      let original = error
      var failures: [String] = []
      func recover(_ body: () throws -> Void) {
        do { try body() } catch { failures.append(String(describing: error)) }
      }
      engine.teardownLocked()
      if publishedBuild { recover { try fileManager.moveItem(at: layout.build, to: layout.buildStaging) } }
      if movedBuild { recover { try fileManager.moveItem(at: layout.buildPrevious, to: layout.build) } }
      if savedPrevious { recover { try fileManager.moveItem(at: previousBackup, to: layout.buildPrevious) } }
      if wroteMetadata { recover { try restoreRecord(metadataBefore, at: layout.metadata) } }
      if wroteActive { recover { try restoreRecord(activeBefore, at: workspace.activeRecord) } }
      recover { try engine.restoreRuntime(runtime) }
      if !failures.isEmpty {
        throw RimeDeploymentFailure.recoveryFailed(original: String(describing: original),
                                                    recovery: failures.joined(separator: "; "))
      }
      throw original
    }
  }

  private func restoreRecord(_ data: Data?, at url: URL) throws {
    if let data { try data.write(to: url, options: .atomic) }
    else if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
  }

  /// The asynchronous form: a real config takes tens of seconds, and the app must stay responsive.
  @discardableResult
  public func deploy(profileID: String,
                     fullCheck: Bool = true,
                     activate: Bool = true,
                     dictionaryWaitTimeout: TimeInterval = 2,
                     progress: (@Sendable (RimeDeploymentProgress) -> Void)? = nil) async throws -> RimeDeploymentOutcome {
    let deadline = Date().addingTimeInterval(max(0, dictionaryWaitTimeout))
    while true {
      try Task.checkCancellation()
      do {
        return try await deployOnce(profileID: profileID, fullCheck: fullCheck,
                                    activate: activate, progress: progress)
      } catch RimeDictionaryAccessError.dictionaryBusy {
        // Ownership is acquired before staging or publication, so retrying this refusal
        // cannot repeat a partial deployment. Never bypass a lock held by a keyboard.
        guard Date() < deadline else { throw RimeDictionaryAccessError.dictionaryBusy }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
    }
  }

  private func deployOnce(profileID: String, fullCheck: Bool, activate: Bool,
                          progress: (@Sendable (RimeDeploymentProgress) -> Void)?) async throws -> RimeDeploymentOutcome {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let outcome = try deploySync(profileID: profileID, fullCheck: fullCheck, activate: activate,
                                       progress: progress)
          continuation.resume(returning: outcome)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Copies the previous generation's derived binaries into staging, isolating compiler writes.
  ///
  /// Only `*.bin`: the compiled tables are the expensive half and librime rewrites them when their
  /// sources change. The deployed **YAML copies are deliberately not seeded** — measured, and it cost
  /// three tests before the reason was clear: librime skips a config it considers up to date, so a
  /// seeded copy survives even when the input it came from was *removed* (a deleted patch, a schema
  /// dropped from `schema_list`), and the deploy then reports success while the old value stays live.
  private static let seededExtensions: Set<String> = ["bin"]

  private func seedStaging(from source: URL, into destination: URL) throws {
    let enumerator = fileManager.enumerator(at: source,
                                            includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [])
    while let item = enumerator?.nextObject() as? URL {
      let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
      let relative = item.path.hasPrefix(source.path + "/")
        ? String(item.path.dropFirst(source.path.count + 1)) : item.lastPathComponent
      let target = destination.appendingPathComponent(relative)
      if values?.isDirectory == true {
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        continue
      }
      guard Self.seededExtensions.contains(item.pathExtension.lowercased()) else { continue }
      if fileManager.fileExists(atPath: target.path) { continue }
      try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
      try fileManager.copyItem(at: item, to: target)
    }
  }

  // MARK: Activate and roll back

  /// Points `active.json` at a profile that already has a usable build, and binds the app's engine
  /// to it. The keyboard adopts this the next time it appears, never mid-composition.
  @discardableResult
  public func activate(profileID: String) throws -> RimeActiveProfile {
    let layout = workspace.profile(profileID)
    let build = layout.buildIsUsable(layout.build) ? layout.build
      : (layout.buildIsUsable(layout.buildPrevious) ? layout.buildPrevious : nil)
    guard let build else { throw RimeDeploymentFailure.buildUnusable(profileID) }

    let metadata = try? workspace.loadMetadata(for: profileID)
    let previous = try? workspace.loadActiveProfile()
    var active = RimeActiveProfile(profileID: profileID,
                                   generation: metadata?.deploy?.generation ?? 1,
                                   engineVersion: RimeEngineVersion.pinned,
                                   sourceDigest: RimeDigest.sha256(ofTree: layout.source))
    if let previous, previous.profileID != profileID {
      active.previousProfileID = previous.profileID
    }
    try workspace.writeActiveProfile(active)
    _ = try engine.rebind(to: RimeBindings.client(workspace: workspace, profileID: profileID,
                                                  buildDirectory: build))
    return active
  }

  /// Restores the previous generation and re-points `active.json` at it: S1 §7's answer to a deploy
  /// that succeeded and then turned out to be broken.
  @discardableResult
  public func rollback(profileID: String) throws -> RimeActiveProfile {
    let layout = workspace.profile(profileID)
    guard layout.buildIsUsable(layout.buildPrevious) else {
      throw RimeDeploymentFailure.rollbackUnavailable(profileID)
    }
    do {
      if fileManager.fileExists(atPath: layout.build.path) {
        try fileManager.removeItem(at: layout.build)
      }
      try fileManager.moveItem(at: layout.buildPrevious, to: layout.build)
    } catch {
      throw RimeDeploymentFailure.activationFailed(String(describing: error))
    }
    var metadata = (try? workspace.loadMetadata(for: profileID))
      ?? RimeProfileMetadata(id: profileID, displayName: profileID, source: RimeProfileSource(kind: .generated))
    let generation = (metadata.deploy?.generation ?? 1) + 1
    metadata.deploy = RimeProfileDeployRecord(generation: generation,
                                              deployedAt: Date(),
                                              engineVersion: RimeEngineVersion.pinned,
                                              durationSeconds: metadata.deploy?.durationSeconds ?? 0,
                                              warnings: ["rolled back to the previous generation"])
    metadata.stats.buildBytes = RimeWorkspace.directorySize(layout.build)
    try workspace.writeMetadata(metadata, fileManager: fileManager)

    var active = RimeActiveProfile(profileID: profileID, generation: generation,
                                   engineVersion: RimeEngineVersion.pinned,
                                   sourceDigest: RimeDigest.sha256(ofTree: layout.source))
    active.previousProfileID = metadata.id
    try workspace.writeActiveProfile(active)
    _ = try engine.rebind(to: RimeBindings.client(workspace: workspace, profileID: profileID,
                                                  buildDirectory: layout.build))
    return active
  }

  // MARK: Library operations

  /// Deletes a profile, asking separately about the user dictionaries it produced (§7). Removing
  /// them is the caller's explicit choice, because they belong to dictionary names, not profiles.
  public func delete(profileID: String, removingUserDictionaries names: [String] = []) throws {
    try workspace.deleteProfile(profileID, removingUserDictionaries: names, fileManager: fileManager)
  }

  /// The list the 配置库 screen shows.
  public func library() throws -> [RimeProfileMetadata] {
    try workspace.loadMetadataList(fileManager: fileManager)
  }
}
