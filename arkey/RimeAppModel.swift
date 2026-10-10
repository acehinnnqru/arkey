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
  @Published private(set) var resolvedSummary = "尚未解析"
  @Published private(set) var engineStatus = "引擎尚未启动"
  @Published private(set) var isDeploying = false
  @Published var deployMessage: String?
  @Published private(set) var latestDeployment: DeploymentAttempt?
  /// S2 §6's footer state. Only the code that writes knows when a change is pending and when it is
  /// live — an activation is "live" without being a deploy — so the transitions happen here rather
  /// than being inferred from whether a message happens to exist.
  @Published var settingsFooter: RimeSettingsFooterState = .unchanged
  /// S5 §6's alternative transport: the folder the user picked, when they picked one.
  @Published var syncChoice: RimeSyncFolderChoice?
  /// Why the stored choice was not used, if it was not.
  @Published var syncChoiceProblem: String?
  @Published var importWarnings: [String] = []
  @Published private(set) var isImporting = false
  @Published var errorMessage: String?
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
  @Published var syncDisabledReason: String?
  /// S5 §4's timestamped backups, per dictionary, newest first. Refreshed with the report rather than
  /// listed on every body pass: the files live in the sync folder, which may be iCloud Drive.
  @Published var dictionaryBackups: [String: [URL]] = [:]
  @Published var notices: RimeNotices?
  @Published var isSyncing = false
  @Published var syncMessage: String?
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
          syncChoiceProblem = "已选同步文件夹不可用，回落到默认目录：" + String(describing: error)
        }
      }
      try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
      _ = try workspace.seedInstallation(syncDirectory: sync)
      // S5 §6: an unreadable installation.yaml is moved aside rather than overwritten, and the user has
      // to know: a new installation id means a new device directory in the sync folder, and the old
      // snapshots will look like another device's.
      if FileManager.default.fileExists(atPath: workspace.quarantinedInstallationURL.path) {
        importWarnings.append("installation.yaml 无法读取，已另存为 installation.yaml.unreadable 并重新生成；"
                              + "同步目录里会多出一个新的设备目录，旧快照会被当成其他设备。")
      }
      try workspace.applyStoragePolicy()
    } catch {
      errorMessage = "工作区初始化失败：" + String(describing: error)
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
          importWarnings.append("已安装本地数据：" + id)
        }
      } catch {
        importWarnings.append("本地数据安装失败：" + String(describing: error))
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
        importWarnings.append("启动清理：移除 " + String(removed) + " 个临时目录，恢复 "
                              + String(outcome.restoredBuilds.count) + " 个上一代构建")
      }
    }
  }

  /// The tracer's vertical slice, against whatever profile is actually bound: if this fails on a
  /// device, the keyboard will fail the same way.
  nonisolated static func typingCheck(engine: RimeEngine) -> String {
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
      let candidate = composing.candidates.first?.text ?? "（无候选）"
      let committed = try engine.selectCandidate(at: 0).commit ?? "（未上屏）"
      try engine.clearComposition()
      let milliseconds = Int(start.milliseconds ?? 0)
      return "librime " + RimeEngine.librimeVersion + " · 启动 " + String(milliseconds)
        + "ms · nihao → " + candidate + " → " + committed
    } catch {
      return "引擎错误：" + String(describing: error)
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
      errorMessage = "读取配置库失败：" + String(describing: error)
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
      errorMessage = "导入失败：" + String(describing: error)
      return
    }
    importWarnings = outcome.warnings.map(\.description)
    if !outcome.userDataCandidates.isEmpty {
      importWarnings.append("发现用户设置 " + String(outcome.userDataCandidates.count)
                            + " 个：" + outcome.userDataCandidates.map(\.relativePath).joined(separator: ", ")
                            + (adoptUserData ? "（已导入）" : "（保留在配置里，未写入用户目录）"))
    }
    if outcome.generatedDefaultYAML != nil {
      importWarnings.append("该配置没有 default.yaml，已生成一个列出 "
                            + String(outcome.metadata.stats.schemaIDs.count) + " 个方案的文件")
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
      errorMessage = "读取配置库失败：" + String(describing: error)
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
      importWarnings = ["已导入 " + String(classification.userData.count) + " 个用户设置文件"]
      refresh()
    } catch {
      errorMessage = "导入用户设置失败：" + String(describing: error)
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
      let text = "没有可部署的配置。"
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
    deployMessage = "正在部署…"
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
      let detail: String
      if rebuilt == 0 {
        detail = "已是最新，未重建任何表，第 " + String(outcome.generation) + " 代"
      } else {
        detail = String(rebuilt) + " 个文件被重建，"
          + String(format: "%.1f s", outcome.durationSeconds) + "，第 " + String(outcome.generation) + " 代"
      }
      deployMessage = "部署完成：" + detail
      latestDeployment?.message = deployMessage ?? detail
      latestDeployment?.logs = outcome.report.logs
      settingsFooter = .applied(detail)
    } catch {
      let reason = String(describing: error)
      let text = "部署失败：" + reason
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
      deployMessage = "已切换。键盘会在下次出现时采用（不会打断正在输入的句子）。"
      settingsFooter = .applied("已切换")
      refresh()
    } catch {
      errorMessage = "切换失败：" + String(describing: error)
    }
  }

  func rollback(profileID: String) {
    do {
      _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).rollback(profileID: profileID)
      deployMessage = "已回滚到上一代构建。"
      settingsFooter = .applied("已回滚到上一代构建")
      refresh()
    } catch {
      errorMessage = "回滚失败：" + String(describing: error)
    }
  }

  func delete(profileID: String, removingUserDictionaries: [String] = []) {
    do {
      try RimeDeploymentCoordinator(workspace: workspace, engine: engine)
        .delete(profileID: profileID, removingUserDictionaries: removingUserDictionaries)
      refresh()
    } catch {
      errorMessage = "删除失败：" + String(describing: error)
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

  static func describe(_ resolved: RimeResolvedProfile) -> String {
    let description: String
    switch resolved.origin {
    case .bundled:
      description = "内置数据（" + (resolved.fallbackReason ?? "未知原因") + "）"
    case .appGroup, .container:
      description = (resolved.profileID ?? "?") + " · 第 " + String(resolved.generation ?? 0) + " 代"
        + (resolved.fallbackReason.map { " · " + $0 } ?? "")
    }
    // The keyboard reads the same table, so the two surfaces cannot disagree about the repair (S1 §9).
    guard let recovery = RimeProfileRecovery.of(resolved) else { return description }
    return description + " · " + recovery.message
  }

  static func describe(_ progress: RimeDeploymentProgress) -> String {
    switch progress.phase {
    case .binding: return "正在绑定配置…"
    case .started: return "librime 开始部署…"
    case .running: return "正在编译词库与方案…（大配置需要几十秒）"
    case .succeeded: return "部署完成"
    case .failed: return "部署失败：" + progress.message
    }
  }
}
