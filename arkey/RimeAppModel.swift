import Combine
import Foundation
import RimeEngine
import SwiftUI

/// Where librime's sync directory points when the user has not chosen one (S5 owns the transport).
enum RimeSyncLocation {
  /// iCloud Drive when the entitlement resolves — the folder Squirrel can also see — and the app's
  /// own Documents directory otherwise, which the Files app can reach through the app's container.
  static func defaultDirectory(workspace: RimeWorkspace) -> URL {
    if let ubiquitous = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
      return ubiquitous.appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("ArkeySync", isDirectory: true)
    }
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? workspace.root
    return documents.appendingPathComponent("ArkeySync", isDirectory: true)
  }
}

private struct LibrarySnapshot: Sendable {
  let profiles: [RimeProfileMetadata]
  let storage: RimeStorageReport
  let activeProfileID: String?
  let resolved: RimeResolvedProfile
  let usableBuilds: Set<String>

  nonisolated static func load(workspace: RimeWorkspace, bundledSharedData: URL) throws -> Self {
    let profiles = try workspace.loadMetadataList()
    let storage = try workspace.storageReport()
    let activeProfileID = try workspace.loadActiveProfile()?.profileID
    let resolved = RimeWorkspaceResolver.resolve(workspace: workspace,
                                                 bundledSharedData: bundledSharedData)
    return Self(profiles: profiles, storage: storage, activeProfileID: activeProfileID,
                resolved: resolved, usableBuilds: Set(profiles.filter {
                  let layout = workspace.profile($0.id)
                  return layout.buildIsUsable(layout.build)
                }.map(\.id)))
  }
}

/// The host app's single librime instance and the workspace behind it.
///
/// librime keeps process-global state, so the app owns exactly one engine: the profile library, the
/// deploy job and the typing check all go through this object rather than building their own.
@MainActor
final class RimeAppModel: ObservableObject {
  static let appGroupID = "group.com.acehinnnqru.arkey"
  static let shared = RimeAppModel()

  @Published private(set) var profiles: [RimeProfileMetadata] = []
  @Published private(set) var storage: RimeStorageReport?
  @Published private(set) var activeProfileID: String?
  @Published private var usableBuilds: Set<String> = []
  @Published private(set) var resolvedSummary = RimeLocalization.message("Not resolved yet")
  @Published private(set) var engineStatus = RimeLocalization.message("Engine has not started")
  @Published private(set) var isDeploying = false
  @Published var deployMessage: RimeLocalizedMessage?
  @Published private(set) var latestDeployment: DeploymentAttempt?
  /// S2 §6's footer state. Only the code that writes knows when a change is pending and when it is
  /// live — an activation is "live" without being a deploy — so the transitions happen here rather
  /// than being inferred from whether a message happens to exist.
  @Published var settingsFooter: RimeSettingsFooterState = .unchanged
  /// S5 §6's alternative transport: the folder the user picked, when they picked one.
  @Published var syncChoice: RimeSyncFolderChoice?
  /// Why the stored choice was not used, if it was not.
  @Published var syncChoiceProblem: RimeLocalizedMessage?
  @Published var importWarnings: [RimeLocalizedMessage] = []
  @Published private(set) var isImporting = false
  @Published var errorMessage: RimeLocalizedMessage?
  @Published var schemas: [String] = []
  /// The 方案 screen's rows and their order, refreshed with the rest of the settings: reading librime
  /// and scanning the profile's sources on every SwiftUI body pass would be a synchronous call per
  /// redraw (and the source scan is a directory walk).
  @Published var schemaRows: [String] = []
  @Published var schemaOrderIDs: [String] = []
  @Published var schemaDescriptor: RimeSchemaDescriptor?
  /// The 模糊音 presets in force, published rather than asked of the engine per redraw.
  @Published var enabledFuzzyPresets: [String] = []
  @Published var dictionaryReport: RimeUserDictionaryReport?
  @Published var syncDisabledReason: RimeLocalizedMessage?
  /// S5 §4's timestamped backups, per dictionary, newest first. Refreshed with the report rather than
  /// listed on every body pass: the files live in the sync folder, which may be iCloud Drive.
  @Published var dictionaryBackups: [String: [URL]] = [:]
  @Published var notices: RimeNotices?
  @Published var isSyncing = false
  @Published var syncMessage: RimeLocalizedMessage?
  @Published var keyboardPreferences: RimeKeyboardPreferences = .standard
  @Published var auxiliarySpelling: RimeAuxiliarySpelling = .fullPinyin
  @Published var customPhrases: [RimeCustomPhrase] = []
  @Published var rejectedPhraseLines: [RimeCustomPhraseFile.RejectedLine] = []
  @Published var enabledKeyBindingOptions: [String] = []
  @Published var punctuationChoices = RimePunctuation.presets.map {
    (preset: $0, isAvailable: $0.requiresFile == nil)
  }
  @Published var currentPunctuationPreset: String?

  /// Invalidate background reads when configuration changes while a page is loading.
  var configurationRevision = 0
  var settingsReadID = UUID()
  var preferencesReadID = UUID()
  var dictionaryReadID = UUID()

  /// The settings writes the user has made and the engine has not been told yet, in the order they were made.
  ///
  /// A settings write ends in a deploy, and librime's deploy holds the engine's own queue for its whole
  /// duration — tens of seconds on a real configuration. So a screen may not write on the tap: the tap would
  /// wait for that deploy. It publishes what the user chose instead and calls `enqueueSettingsWrite`, which is
  /// this queue. The value the queue holds is laid back over the engine's own answer by `refreshSettings()`,
  /// so a control keeps showing the last choice until a deploy makes it true — and a write that arrives while
  /// another is deploying is not dropped, which is what used to leave a change written and never deployed.
  var pendingSettingsWrites: [RimeSettingsIntent] = []
  /// The task working through `pendingSettingsWrites`; nil when nothing is queued or running.
  var settingsWriter: Task<Void, Never>?
  /// The deploy in flight, so a settings write can wait for it rather than touch librime's configuration
  /// underneath it.
  var deployInFlight: Task<Void, Never>?
  /// True when a screen asked for a settings read while a deploy was holding the engine's queue, and was told
  /// to keep what it had. The deploy that refused it reads it back when it ends (`refreshSettings()`).
  var settingsRefreshDeferred = false

  let workspace: RimeWorkspace
  let bundledSharedData: URL
  private(set) var engine: RimeEngine
  private(set) var resolved: RimeResolvedProfile?
  private var didBootstrap = false

  init() {
    let shared = RimeDirectories.bundledSharedDataURL()
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("RimeData", isDirectory: true)
    bundledSharedData = shared
    workspace = RimeWorkspace.locate(appGroupID: Self.appGroupID)
    let resolved = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: shared)
    self.resolved = resolved
    engine = RimeEngine(configuration: RimeConfiguration(directories: resolved.directories, minLogLevel: 0),
                        dictionaryLeaseStore: RimeLeaseStore(workspace: workspace))
    resolvedSummary = Self.describe(resolved)
  }

  // MARK: - Bootstrap

  /// Everything the app does before it is usable: seed the installation record, bind librime to the
  /// profile the keyboard will also read, and run the tracer's typing check as a diagnostic.
  func bootstrap() async {
    guard !didBootstrap else { return }
    didBootstrap = true
    do {
      try workspace.createDirectories()
      // S5 §6: the user's chosen folder wins over the default, and a choice that no longer validates
      // (the folder was deleted, or access was revoked) falls back with a sentence rather than a
      // silent write into the wrong place.
      var sync = RimeSyncLocation.defaultDirectory(workspace: workspace)
      if let choice = workspace.loadSyncChoice() {
        do {
          sync = try choice.validate()
        } catch {
          syncChoiceProblem = RimeLocalization.message("Selected sync folder is unavailable; using the default folder: \(String(describing: error))")
        }
      }
      try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
      _ = try workspace.seedInstallation(syncDirectory: sync)
      // S5 §6: an unreadable installation.yaml is moved aside rather than overwritten, and the user has
      // to know: a new installation id means a new device directory in the sync folder, and the old
      // snapshots will look like another device's.
      if FileManager.default.fileExists(atPath: workspace.quarantinedInstallationURL.path) {
        importWarnings.append(RimeLocalization.message("installation.yaml could not be read. It was saved as installation.yaml.unreadable and regenerated. A new device folder will appear in the sync folder; old snapshots will be treated as another device."))
      }
      try workspace.applyStoragePolicy()
    } catch {
      errorMessage = RimeLocalization.message("Failed to initialize workspace: \(String(describing: error))")
    }
    #if DEBUG
    // S1-AC6: a Debug build may carry a local config, and the app starts with it installed. The Release
    // check refuses the directory in a bundle (S6-AC3), so this branch is the convenience half of the
    // criterion and the check is the safety half.
    if let localData = Bundle.main.url(forResource: RimeLocalDataInstaller.directoryName,
                                       withExtension: nil) {
      do {
        if let id = try RimeLocalDataInstaller.installIfPresent(at: localData, workspace: workspace,
                                                                 engine: engine) {
          importWarnings.append(RimeLocalization.message("Installed local data: \(id)"))
        }
      } catch {
        importWarnings.append(RimeLocalization.message("Failed to install local data: \(String(describing: error))"))
      }
    }
    #endif
    refresh()
    // Repair a published generation that contains tables/default.yaml but has lost an enabled
    // schema. Maintenance runs in the host app, with the coordinator's rollback protection.
    if let id = activeProfileID, resolved?.profileID == id {
      do {
        _ = try engine.start()
        let schemaIDs = try workspace.loadMetadata(for: id)?.stats.schemaIDs ?? []
        let repairs = try RimePunctuation.repairLegacySymbolImports(
          schemaIDs: schemaIDs, engine: engine,
          backupDirectory: workspace.root.appendingPathComponent("backups")
            .appendingPathComponent("punctuation-" + UUID().uuidString))
        for repair in repairs { recordConfigChange(repair) }
        let missing = try engine.unusableDeployedSchemaIDs()
        let hasUsableSession: Bool = try {
          try engine.openSession()
          defer { engine.closeSession() }
          guard let schema = try engine.currentSchema(), schema != ".default" else { return false }
          return try engine.hasInputProcessors(schemaID: schema)
        }()
        if !repairs.isEmpty || !missing.isEmpty || !hasUsableSession {
          RimeProbeLog(url: workspace.log.appendingPathComponent("probe.jsonl"))
            .append(RimeProbeRecord(phase: "app.schema.repair",
                                    message: "Redeploying unusable input configuration; missing schemas: "
                                      + missing.joined(separator: ", ")))
          await deploy(profileID: id)
        }
      } catch {
        RimeProbeLog(url: workspace.log.appendingPathComponent("probe.jsonl"))
          .append(RimeProbeRecord(phase: "app.schema.check.failed", message: String(describing: error)))
      }
    }
    engineStatus = Self.typingCheck(engine: engine)
    if let outcome = RimeWorkspaceJanitor().run(workspace: workspace) as RimeWorkspaceJanitor.Outcome? {
      let removed = outcome.removedStagingEntries.count + outcome.removedBuildStaging.count
      if removed > 0 || !outcome.restoredBuilds.isEmpty {
        importWarnings.append(RimeLocalization.message("Startup cleanup: removed \(String(removed)) temporary folders and restored \(String(outcome.restoredBuilds.count)) previous builds"))
      }
    }
  }

  /// The tracer's vertical slice, against whatever profile is actually bound: if this fails on a
  /// device, the keyboard will fail the same way.
  nonisolated static func typingCheck(engine: RimeEngine) -> RimeLocalizedMessage {
    do {
      let start = try engine.start()
      try engine.openSession()
      defer { engine.closeSession() }
      let probe = RimeProbeLog(url: URL(fileURLWithPath: engine.directories.logDir)
        .appendingPathComponent("probe.jsonl"))
      probe.append(RimeProbeRecord(phase: "app.configuration",
                                  message: try engine.inputConfigurationSummary()))
      let composing = try engine.processKeys("nihao")
      probe.append(RimeProbeRecord(phase: "app.typingCheck",
                                  message: "handled=" + String(composing.handled)
                                    + " composing=" + String(composing.isComposing)
                                    + " candidates=" + String(composing.candidates.count)
                                    + " asciiMode=" + String(composing.status?.isAsciiMode ?? false)))
      let candidate = (composing.candidates.first?.text).map(RimeLocalizedMessage.init(verbatim:)) ?? RimeLocalization.message("(no candidates)")
      let committed = try engine.selectCandidate(at: 0).commit.map(RimeLocalizedMessage.init(verbatim:)) ?? RimeLocalization.message("(no committed text)")
      try engine.clearComposition()
      let milliseconds = Int(start.milliseconds ?? 0)
      return RimeLocalization.message("librime \(RimeEngine.librimeVersion) · startup \(String(milliseconds))ms · nihao → \(candidate) → \(committed)")
    } catch {
      return RimeLocalization.message("Engine error: \(String(describing: error))")
    }
  }

  // MARK: - Library

  func refresh() {
    configurationRevision += 1
    do {
      profiles = try workspace.loadMetadataList()
      storage = try workspace.storageReport()
      activeProfileID = try workspace.loadActiveProfile()?.profileID
      usableBuilds = Set(profiles.filter {
        let layout = workspace.profile($0.id)
        return layout.buildIsUsable(layout.build)
      }.map(\.id))
    } catch {
      errorMessage = RimeLocalization.message("Failed to read profile library: \(String(describing: error))")
    }
    let current = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: bundledSharedData)
    resolved = current
    resolvedSummary = Self.describe(current)
  }

  var libraryEntries: [LibraryEntry] {
    let buildBytes = Dictionary(uniqueKeysWithValues: (storage?.profiles ?? []).map { ($0.id, $0.buildBytes) })
    return profiles.map { metadata in
      return LibraryEntry(metadata: metadata,
                          buildBytes: usableBuilds.contains(metadata.id)
                            ? (buildBytes[metadata.id] ?? 0) : 0,
                          isActive: metadata.id == activeProfileID)
    }
  }

  struct LibraryEntry: Identifiable {
    let metadata: RimeProfileMetadata
    let buildBytes: Int
    let isActive: Bool
    var id: String { metadata.id }
  }

  // MARK: - Import

  /// The picker hands back a security-scoped URL; the scope is held for the whole pipeline.
  func importPayload(at url: URL, displayName: String?, adoptUserData: Bool) async {
    guard !isImporting else { return }
    isImporting = true
    defer { isImporting = false }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let workspace = self.workspace
    let engine = self.engine
    let bundledSharedData = self.bundledSharedData
    let outcome: RimeImportOutcome
    do {
      outcome = try await Task.detached(priority: .userInitiated) {
        return try RimeImporter(workspace: workspace, engine: engine).import(
          payload: url,
          options: RimeImportOptions(
            displayName: displayName ?? url.deletingPathExtension().lastPathComponent,
            origin: RimeProfileSource(kind: .files, url: url.absoluteString, retrievedAt: Date()),
            license: RimeProfileLicense.unknown,
            adoptUserData: adoptUserData))
      }.value
    } catch {
      errorMessage = RimeLocalization.message("Import failed: \(String(describing: error))")
      return
    }
    importWarnings = outcome.warnings.map { RimeLocalizedMessage(verbatim: $0.description) }
    if !outcome.userDataCandidates.isEmpty {
      importWarnings.append(RimeLocalization.message("Found user settings: \(String(outcome.userDataCandidates.count)) files: \(outcome.userDataCandidates.map(\.relativePath).joined(separator: ", "))\((adoptUserData ? RimeLocalization.message(" (imported)") : RimeLocalization.message(" (kept in profile; not copied to user directory)")))"))
    }
    if outcome.generatedDefaultYAML != nil {
      importWarnings.append(RimeLocalization.message("This profile has no default.yaml; generated one containing \(String(outcome.metadata.stats.schemaIDs.count)) schemes"))
    }
    // The library scan includes directory sizes and can be substantial after a large import.
    do {
      let snapshot = try await Task.detached(priority: .userInitiated) {
        try LibrarySnapshot.load(workspace: workspace, bundledSharedData: bundledSharedData)
      }.value
      profiles = snapshot.profiles
      storage = snapshot.storage
      activeProfileID = snapshot.activeProfileID
      usableBuilds = snapshot.usableBuilds
      resolved = snapshot.resolved
      resolvedSummary = Self.describe(snapshot.resolved)
    } catch {
      errorMessage = RimeLocalization.message("Failed to read profile library: \(String(describing: error))")
    }
  }

  func adoptUserData(at url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let importer = RimeImporter(workspace: workspace, engine: engine)
    do {
      let root = try RimeConfigRootLocator.locate(in: url)
      let classification = RimeTreeClassifier.classify(root: root)
      try importer.adopt(classification.userData, from: root)
      importWarnings = [RimeLocalization.message("Imported \(String(classification.userData.count)) user settings files")]
      refresh()
    } catch {
      errorMessage = RimeLocalization.message("Failed to import user settings: \(String(describing: error))")
    }
  }

  // MARK: - Deploy and activation

  func deploy(profileID: String) async {
    // A deploy already running is waited for, not dropped. The callers write a file and then deploy it, so a
    // dropped request leaves that file written and not live — the change looks applied on the screen and never
    // reaches the keyboard. librime runs one maintenance at a time, so this is a queue, not a courtesy.
    while let running = deployInFlight {
      await running.value
    }
    let task = Task { @MainActor in await self.runDeploy(profileID: profileID) }
    deployInFlight = task
    await task.value
    if deployInFlight == task {
      deployInFlight = nil
      // A screen that asked for a settings read while this deploy ran was told to keep what it had rather than
      // wait for the deploy. It gets the answer here, now that the engine's queue is free.
      if settingsRefreshDeferred { await refreshSettings() }
    }
  }

  private func runDeploy(profileID: String) async {
    // An empty id is what "there is nothing to deploy into" looks like to the callers that write a file and
    // then deploy it — the phrase list and the settings import both do. Without this the coordinator builds the
    // path `profiles//source` and fails with an English, path-bearing sentence, which is what a user with no
    // profile reads after adding a phrase. Say what redeployActiveProfile() says instead.
    guard !profileID.isEmpty else {
      let text = RimeLocalization.message("No profile is available to deploy.")
      deployMessage = text
      errorMessage = text
      settingsFooter = .failed(text)
      return
    }
    isDeploying = true
    let attempt = DeploymentAttempt(profileID: profileID,
                                    profileName: profiles.first { $0.id == profileID }?.displayName ?? profileID)
    latestDeployment = attempt
    settingsFooter = .pending
    deployMessage = RimeLocalization.message("Deploying…")
    let coordinator = RimeDeploymentCoordinator(workspace: workspace, engine: engine)
    do {
      let outcome = try await coordinator.deploy(profileID: profileID) { progress in
        Task { @MainActor in
          guard self.latestDeployment?.id == attempt.id,
                self.latestDeployment?.finishedAt == nil else { return }
          self.deployMessage = Self.describe(progress)
          self.latestDeployment?.message = Self.describe(progress)
        }
      }
      // S1 §6: a deploy can succeed while having written nothing (librime's staleness check runs once
      // per process), so the message says which of the two happened instead of implying work.
      let rebuilt = outcome.report.changes.writtenTables.count
      let detail: RimeLocalizedMessage
      if rebuilt == 0 {
        detail = RimeLocalization.message("Up to date; no tables rebuilt. Generation \(String(outcome.generation))")
      } else {
        detail = RimeLocalization.message("\(String(rebuilt)) files rebuilt, \(String(format: "%.1f s", outcome.durationSeconds)), generation \(String(outcome.generation))")
      }
      deployMessage = RimeLocalization.message("Deployment complete: \(detail)")
      latestDeployment?.message = deployMessage ?? detail
      latestDeployment?.logs = outcome.report.logs
      settingsFooter = .applied(detail)
    } catch {
      let reason = String(describing: error)
      let text = RimeLocalization.message("Deployment failed: \(reason)")
      RimeProbeLog(url: workspace.log.appendingPathComponent("probe.jsonl"))
        .append(RimeProbeRecord(phase: "app.deploy.failed", message: reason))
      if case RimeDeploymentFailure.deployFailed(let report) = error {
        latestDeployment?.logs = report.logs
        // The final error is often only "error building config"; earlier compiler errors name
        // the missing include or invalid patch. Use this deployment's report, never typing logs.
        let diagnostics = report.logs.filter { $0.severity >= .warning }.map(\.display)
        RimeProbeLog(url: workspace.log.appendingPathComponent("probe.jsonl"))
          .append(RimeProbeRecord(phase: "app.deploy.diagnostics",
                                  message: diagnostics.suffix(80).joined(separator: "\n")))
      }
      deployMessage = text
      latestDeployment?.message = text
      latestDeployment?.failed = true
      errorMessage = text
      // The reason only: the footer adds the label itself, so the sentence is not doubled.
      settingsFooter = .failed(reason)
    }
    latestDeployment?.finishedAt = Date()
    isDeploying = false
    refresh()
  }

  func activate(profileID: String) {
    do {
      _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).activate(profileID: profileID)
      recordProfileActivation(profileID)
      deployMessage = RimeLocalization.message("Profile changed. The keyboard adopts it next time it opens, without interrupting current input.")
      settingsFooter = .applied(RimeLocalization.message("Profile changed"))
      refresh()
    } catch {
      errorMessage = RimeLocalization.message("Failed to switch: \(String(describing: error))")
    }
  }

  func rollback(profileID: String) {
    do {
      _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).rollback(profileID: profileID)
      deployMessage = RimeLocalization.message("Rolled back to the previous build.")
      settingsFooter = .applied(RimeLocalization.message("Rolled back to the previous build"))
      refresh()
    } catch {
      errorMessage = RimeLocalization.message("Rollback failed: \(String(describing: error))")
    }
  }

  func delete(profileID: String, removingUserDictionaries: [String] = []) {
    do {
      try RimeDeploymentCoordinator(workspace: workspace, engine: engine)
        .delete(profileID: profileID, removingUserDictionaries: removingUserDictionaries)
      refresh()
    } catch {
      errorMessage = RimeLocalization.message("Delete failed: \(String(describing: error))")
    }
  }

  /// The dictionary names a profile produced, asked about when the profile is deleted (§7).
  ///
  /// This was the same seven lines as the engine's `RimeSyncService.discoveredDatabaseNames()` — two copies of
  /// one scan, one of them untested — so the app asks the engine now.
  var userDatabaseNames: [String] {
    RimeSyncService(workspace: workspace, engine: engine).discoveredDatabaseNames()
  }

  // MARK: - Descriptions

  /// S1 §9's repair, when there is one: the banner reads this, so the wording and the button next to it
  /// come from the same table the keyboard uses.
  var recovery: RimeProfileRecovery? {
    resolved.flatMap(RimeProfileRecovery.of)
  }

  static func describe(_ resolved: RimeResolvedProfile) -> RimeLocalizedMessage {
    let description: RimeLocalizedMessage
    switch resolved.origin {
    case .bundled:
      description = RimeLocalization.message("Built-in data (\((resolved.fallbackReason.map(RimeLocalizedMessage.init(verbatim:)) ?? RimeLocalization.message("Unknown reason"))))")
    case .appGroup, .container:
      description = RimeLocalization.message("\((resolved.profileID ?? "?")) · generation \(String(resolved.generation ?? 0))\((resolved.fallbackReason.map { " · " + $0 } ?? ""))")
    }
    // The keyboard reads the same table, so the two surfaces cannot disagree about the repair (S1 §9).
    guard let recovery = RimeProfileRecovery.of(resolved) else { return description }
    return description + " · " + recovery.localizedMessage
  }

  static func describe(_ progress: RimeDeploymentProgress) -> RimeLocalizedMessage {
    switch progress.phase {
    case .binding: return RimeLocalization.message("Binding profile…")
    case .started: return RimeLocalization.message("librime is starting deployment…")
    case .running: return RimeLocalization.message("Compiling dictionaries and schemes… (large profiles may take tens of seconds)")
    case .succeeded: return RimeLocalization.message("Deployment complete")
    case .failed: return RimeLocalization.message("Deployment failed: \(progress.message)")
    }
  }
}
