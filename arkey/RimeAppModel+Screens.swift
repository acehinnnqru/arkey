import Combine
import Foundation
import RimeEngine
import SwiftUI

private struct DictionarySnapshot: Sendable {
  let choice: RimeSyncFolderChoice?
  let report: RimeUserDictionaryReport?
  let backups: [String: [URL]]
  let error: String?
  let syncDisabledReason: RimeLocalizedMessage?

  nonisolated static func load(workspace: RimeWorkspace, engine: RimeEngine) -> Self {
    let service = RimeSyncService(workspace: workspace, engine: engine)
    let choice = workspace.loadSyncChoice()
    let reason = RimeAppModel.dictionarySyncDisabledReason(engine: engine)
    do {
      let report = try service.report()
      let backups = Dictionary(uniqueKeysWithValues: report.dictionaries.map { entry in
        (entry.name, service.backups(for: entry.name))
      })
      return Self(choice: choice, report: report, backups: backups, error: nil,
                  syncDisabledReason: reason)
    } catch {
      return Self(choice: choice, report: nil, backups: [:], error: String(describing: error),
                  syncDisabledReason: reason)
    }
  }
}

/// The app's own screens, in one place: what the workspace holds, and the few writes the UI may make.
///
/// Everything here goes through the same single engine the keyboard contract is built on, and the
/// engine's own models do the deciding — this type is the seam between them and SwiftUI, not a second
/// implementation of anything.
@MainActor
extension RimeAppModel {
  // MARK: - Settings (S2)

  /// Which schema the settings screens are editing: the deployed one if there is one, the first otherwise.
  var settingsSchemaID: String? {
    if let current = try? engine.currentSchema(), !current.isEmpty { return current }
    return schemas.first
  }

  /// A SwiftUI task inherits the main actor; only the detached read may wait on librime or disk.
  /// Pending choices are applied to the snapshot before it becomes visible.
  func refreshSettings() async {
    guard deployInFlight == nil else {
      settingsRefreshDeferred = true
      return
    }
    let readID = UUID()
    settingsReadID = readID
    let revision = configurationRevision
    let engine = self.engine
    let source = settingsSource
    let punctuationSource = activeProfileID.map { workspace.profile($0).source }
    let snapshot = await Task.detached(priority: .userInitiated) {
      RimeSettingsSnapshot.load(engine: engine, source: source, punctuationSource: punctuationSource)
    }.value
    guard !Task.isCancelled, settingsReadID == readID else { return }
    if configurationRevision != revision {
      await refreshSettings()
      return
    }
    guard deployInFlight == nil else {
      settingsRefreshDeferred = true
      return
    }
    settingsRefreshDeferred = false
    applySettingsSnapshot(snapshot)
  }

  private var settingsSource: URL? {
    (activeProfileID ?? profiles.first?.id).map { workspace.profile($0).source }
  }

  private func applySettingsSnapshot(_ snapshot: RimeSettingsSnapshot) {
    schemas = snapshot.schemas
    schemaRows = snapshot.rows
    punctuationChoices = snapshot.punctuationChoices
    currentPunctuationPreset = snapshot.punctuationPreset
    var descriptor = snapshot.descriptor
    if let error = snapshot.error {
      errorMessage = RimeLocalization.message("Failed to read schema settings: \(error)")
    }

    // The queue is the overlay, so the two cannot disagree: what is queued is exactly what is not deployed.
    var order = snapshot.order
    var fuzzy: [String]?
    for intent in pendingSettingsWrites {
      switch intent {
      case .schemaList(let ids):
        order = ids
      case .switchReset(_, let name, let reset):
        descriptor = descriptor?.replacingSwitchReset(reset, forSwitch: name)
      case .setting(_, let key, let value):
        descriptor = descriptor?.replacingSetting(value, forKey: key)
      case .resetSetting(_, let key):
        descriptor = descriptor?.clearingSetting(key)
      case .fuzzyPresets(_, let enabled):
        fuzzy = enabled
      case .auxiliaryPrefix, .auxiliarySpelling:
        break
      }
    }

    schemaDescriptor = descriptor
    schemaOrderIDs = order
    enabledFuzzyPresets = fuzzy ?? snapshot.fuzzyPresets
  }

  /// Writes one translator setting and redeploys, which is the only path S2 allows: shipped sources are
  /// read-only and a change reaches the keyboard through a deploy.
  ///
  /// The row shows the chosen value before any of that happens, and the write itself is queued — see
  /// `RimeAppModel.pendingSettingsWrites`. Writing here would be a synchronous engine call on the main actor,
  /// and a deploy holds the engine's queue for tens of seconds on a real configuration.
  ///
  /// The schema is the one the screen is showing, taken from the descriptor the row came out of, and not asked
  /// of the engine: `settingsSchemaID` is a read on that same queue, so asking it here reintroduces the wait
  /// this method exists to avoid.
  func setSetting(_ descriptor: RimeSettingDescriptor, value: RimeSettingDescriptor.Value) {
    guard let id = schemaDescriptor?.schemaID else { return }
    schemaDescriptor = schemaDescriptor?.replacingSetting(value, forKey: descriptor.key)
    enqueueSettingsWrite(.setting(configID: configID(for: descriptor.scope, schemaID: id),
                                  key: descriptor.key, value: value))
  }

  /// Reset deletes the key from the patch, so the schema's own value comes back (S2 §4).
  func resetSetting(_ descriptor: RimeSettingDescriptor) {
    guard let id = schemaDescriptor?.schemaID else { return }
    schemaDescriptor = schemaDescriptor?.clearingSetting(descriptor.key)
    enqueueSettingsWrite(.resetSetting(configID: configID(for: descriptor.scope, schemaID: id),
                                       key: descriptor.key))
  }

  /// A switch default is the whole list, not an index (measured: patching `switches/@N/reset` replaces
  /// the list and leaves one nameless entry).
  func setSwitch(_ name: String, reset: Int) {
    guard let id = schemaDescriptor?.schemaID else { return }
    schemaDescriptor = schemaDescriptor?.replacingSwitchReset(reset, forSwitch: name)
    enqueueSettingsWrite(.switchReset(schemaID: id, name: name, reset: reset))
  }

  /// 模糊音 is composed into `speller/algebra` from the schema's own algebra, never appended (S2 §2.1).
  func setFuzzyPinyin(_ enabled: [String]) {
    guard let id = schemaDescriptor?.schemaID else { return }
    enabledFuzzyPresets = enabled
    enqueueSettingsWrite(.fuzzyPresets(schemaID: id, enabled: enabled))
  }

  // MARK: - Schema list (S2 §3, 方案)

  /// The schemas the active profile ships, enabled or not. librime's own list names only the enabled
  /// ones, so the ones that are off are read from the profile's sources.
  var installedSchemaIDs: [String] {
    guard let id = activeProfileID ?? profiles.first?.id else { return [] }
    return RimeTreeClassifier.classify(root: workspace.profile(id).source).schemaIDs
  }

  /// Publish the choice before queuing the write so selection never waits on the engine's deployment queue.
  private func setSchemaList(_ ids: [String]) {
    guard ids != schemaOrderIDs else { return }
    schemaOrderIDs = ids
    enqueueSettingsWrite(.schemaList(ids))
  }

  /// Selecting a row replaces the enabled list, including imported lists with multiple schemas.
  /// Selecting the same row again cannot turn off the only input scheme.
  func selectInputSchema(_ id: String) {
    guard schemaRows.contains(id) else { return }
    setSchemaList([id])
  }

  func schemaListEditor() -> RimeSchemaListEditor {
    RimeSchemaListEditor(engine: engine, installed: installedSchemaIDs)
  }

  /// S2 §5.5: an applied change is recorded in the same log the keyboard writes, so one file tells
  /// the whole story of a device run. Only the config values go in — never the composition or the
  /// candidates the user saw (S6 §3; `S6ProbePrivacyTests` checks the log's field set).
  func recordConfigChange(_ change: RimeConfigChange) {
    guard let url = ProbeLogLocation.groupLogURL else { return }
    RimeProbeLog(url: url).append(RimeProbeRecord.configApplied(change))
  }

  /// S6 §3: the log keeps profile activations, so "which build was the keyboard on" has an answer.
  func recordProfileActivation(_ profileID: String) {
    guard let url = ProbeLogLocation.groupLogURL else { return }
    let generation = (try? workspace.loadActiveProfile())?.generation
    RimeProbeLog(url: url).append(RimeProbeRecord.profileActivated(profileID: profileID,
                                                                   generation: generation))
  }

  private func configID(for scope: RimeSettingDescriptor.Scope, schemaID: String) -> String {
    if case .schema(let id) = scope { return id }
    return "default"
  }

  // MARK: - User dictionary (S5)

  func refreshDictionaries() {
    dictionaryReadID = UUID()
    applyDictionarySnapshot(DictionarySnapshot.load(workspace: workspace, engine: engine))
  }

  /// S5 §4/§5: one backup on demand, beside the snapshot and pruned to the last three.
  func backupDictionary(_ name: String) {
    do {
      let service = RimeSyncService(workspace: workspace, engine: engine)
      guard try service.backup(dictionary: name) != nil else {
        errorMessage = RimeLocalization.message("Backup failed: no snapshot exists in the sync folder and librime could not create one.")
        return
      }
      syncMessage = RimeLocalization.message("Backed up \(name)")
      refreshDictionaries()
    } catch {
      errorMessage = RimeLocalization.message("Backup failed: \(String(describing: error))")
    }
  }

  /// Restores a backup through librime's own door. The file is the snapshot format, which is what
  /// `restore_user_dict` reads; the levers export would be recorded as spellings instead (S5 §5).
  func restoreDictionary(_ name: String, from url: URL) {
    do {
      let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
      _ = try access.perform { try engine.restoreUserDictionary(snapshotFile: url) }
      syncMessage = RimeLocalization.message("Restored from \(url.lastPathComponent) dictionary \(name)")
      refreshDictionaries()
    } catch {
      errorMessage = RimeLocalization.message("Restore failed: \(String(describing: error))")
    }
  }

  func syncDictionaries() async {
    guard !isSyncing else { return }
    isSyncing = true
    syncMessage = RimeLocalization.message("Syncing…")
    let workspace = self.workspace
    let engine = self.engine
    do {
      let outcome = try await Task.detached(priority: .userInitiated) {
        try RimeSyncService(workspace: workspace, engine: engine).syncNow()
      }.value
      syncMessage = outcome.succeeded
        ? RimeLocalization.message("Sync complete: \(String(outcome.snapshots.count)) snapshots, \(String(format: "%.1f s", outcome.duration))")
        : RimeLocalization.message("Sync failed: \((outcome.failureReason ?? ""))")
    } catch {
      syncMessage = RimeLocalization.message("Sync failed: \(String(describing: error))")
      errorMessage = syncMessage
    }
    await refreshDictionariesInBackground()
    isSyncing = false
  }

  /// S5 §6/§10: read every other device's snapshot in the shared folder and merge it in additively.
  /// The engine converts each one to the levers format first, because `restore_user_dict` would
  /// replace this device's words with the other device's instead of joining them.
  func mergeDictionaries(from deviceID: String? = nil) async {
    guard !isSyncing else { return }
    isSyncing = true
    let workspace = self.workspace
    let engine = self.engine
    do {
      let outcome = try await Task.detached(priority: .userInitiated) {
        try RimeSyncService(workspace: workspace, engine: engine)
          .mergeFromOtherDevices(devices: deviceID.map { [$0] })
      }.value
      if outcome.isEmpty {
        syncMessage = RimeLocalization.message("No snapshots from other devices exist in the sync folder.")
      } else {
        let devices = Set(outcome.entries.flatMap(\.deviceIDs)).sorted().joined(separator: "、")
        let read = outcome.entries.reduce(0) { $0 + $1.entriesRead }
        syncMessage = RimeLocalization.message("Restored from \(devices) merged \(String(outcome.entries.count)) dictionaries: read \(String(read)) entries, added \(String(outcome.totalImported)) entries")
      }
    } catch {
      syncMessage = RimeLocalization.message("Merge failed: \(String(describing: error))")
      errorMessage = syncMessage
    }
    await refreshDictionariesInBackground()
    isSyncing = false
  }

  func refreshDictionariesInBackground() async {
    await refreshPersonalDictionary()
    let readID = UUID()
    dictionaryReadID = readID
    let revision = configurationRevision
    let workspace = self.workspace
    let engine = self.engine
    let snapshot = await Task.detached(priority: .userInitiated) {
      DictionarySnapshot.load(workspace: workspace, engine: engine)
    }.value
    guard !Task.isCancelled, dictionaryReadID == readID else { return }
    if revision != configurationRevision {
      await refreshDictionariesInBackground()
      return
    }
    applyDictionarySnapshot(snapshot)
  }

  private func applyDictionarySnapshot(_ snapshot: DictionarySnapshot) {
    syncChoice = snapshot.choice
    dictionaryReport = snapshot.report
    dictionaryBackups = snapshot.backups
    syncDisabledReason = snapshot.syncDisabledReason
    if let error = snapshot.error {
      errorMessage = RimeLocalization.message("Failed to read user dictionaries: \(error)")
    }
  }

  // MARK: - The sync folder (S5 §6)

  /// S5 §6: the user picks a folder, the app holds a bookmark for it, validates it and re-seeds
  /// `installation.yaml` — the file librime actually reads. The default (iCloud Drive) comes back by
  /// choosing nil.
  func chooseSyncFolder(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let bookmark = try url.bookmarkData()
      let choice = RimeSyncFolderChoice(path: url.path, bookmark: bookmark)
      let validated = try choice.validate()
      try workspace.saveSyncChoice(choice)
      _ = try workspace.setSyncDirectory(validated)
      syncChoice = choice
      syncChoiceProblem = nil
      deployMessage = RimeLocalization.message("Sync folder changed to \(validated.path)")
      settingsFooter = .applied(RimeLocalization.message("Sync folder updated"))
      refreshDictionaries()
    } catch {
      errorMessage = RimeLocalization.message("Failed to choose sync folder: \(String(describing: error))")
    }
  }

  func useDefaultSyncFolder() {
    do {
      try workspace.saveSyncChoice(nil)
      let fallback = RimeSyncLocation.defaultDirectory(workspace: workspace)
      try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
      _ = try workspace.setSyncDirectory(fallback)
      syncChoice = nil
      syncChoiceProblem = nil
      deployMessage = RimeLocalization.message("Sync folder restored to default: \(fallback.path)")
      settingsFooter = .applied(RimeLocalization.message("Sync folder updated"))
      refreshDictionaries()
    } catch {
      errorMessage = RimeLocalization.message("Failed to restore default sync folder: \(String(describing: error))")
    }
  }

  /// Removes a dictionary entirely. This is the deletion librime's levers API leaves us: import is
  /// additive, so a single word is forgotten from the keyboard's candidate bar (S4 §8), not here.
  func removeDictionary(_ name: String) {
    do {
      try RimePersonalDictionaryService(workspace: workspace, engine: engine).pauseBeforeClearing(name)
      let editor = RimeDictionaryEditor(workspace: workspace, engine: engine)
      _ = try editor.removeDictionary(name)
      personalDictionary = try RimePersonalDictionaryService(workspace: workspace, engine: engine).load()
      refreshDictionaries()
      Task { await refreshPersonalDictionary() }
    } catch {
      errorMessage = RimeLocalization.message("Failed to delete dictionary: \(String(describing: error))")
    }
  }

  /// Exports the levers format, which Squirrel does **not** read: the user's own file, not the sync
  /// transport. The screen says which of the two it is writing.
  func exportDictionary(_ name: String) -> URL? {
    let url = workspace.root.appendingPathComponent("exports", isDirectory: true)
      .appendingPathComponent(name + "-export.txt")
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
      let service = RimeSyncService(workspace: workspace, engine: engine)
      _ = try service.exportDictionary(name, to: url)
      return url
    } catch {
      errorMessage = RimeLocalization.message("Export failed: \(String(describing: error))")
      return nil
    }
  }

  /// S5 §5's other file: the **sync snapshot**, which is the one Squirrel reads. The levers export above is
  /// for this app's own import; this one is for handing a dictionary to the desktop without going through
  /// iCloud, and it is the same file the sync folder receives.
  func exportSnapshot(_ name: String) -> URL? {
    do {
      let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
      _ = try access.perform { try engine.backupUserDictionary(name) }
      let service = RimeSyncService(workspace: workspace, engine: engine)
      guard let device = service.deviceDirectory else { return nil }
      let url = device.appendingPathComponent(name + ".userdb.txt")
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return url
    } catch {
      errorMessage = RimeLocalization.message("Failed to export snapshot: \(String(describing: error))")
      return nil
    }
  }

  /// S5 §5's second export: **the whole set as one zip**, in the sync folder's own shape
  /// (`<installation_id>/<dict>.userdb.txt`), so it can be handed to another machine and unzipped over
  /// a sync folder — or imported here through the same shape-detecting path.
  func exportAllDictionaries() -> URL? {
    let url = workspace.root.appendingPathComponent("exports", isDirectory: true)
      .appendingPathComponent("arkey-dictionaries.zip")
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
      let export = try RimeSyncService(workspace: workspace, engine: engine)
        .exportAllSnapshots(to: url)
      syncMessage = RimeLocalization.message("Exported \(String(export.dictionaries.count)) dictionary snapshots (\(RimeProbe.formatted(bytes: UInt64(export.bytes))))")
      return url
    } catch {
      errorMessage = RimeLocalization.message("Failed to export all snapshots: \(String(describing: error))")
      return nil
    }
  }

  /// S5 §5's "Import from Files": a Squirrel snapshot or this app's own levers export, told apart by shape
  /// rather than by which button was pressed. The engine backs the dictionary up before the import (S5-AC3),
  /// and the access gate refuses while the keyboard holds the lease. Returns the sentence to show, or "" when
  /// it failed — the error is on `errorMessage` then.
  func importDictionary(from url: URL, into name: String) -> RimeLocalizedMessage {
    let service = RimeSyncService(workspace: workspace, engine: engine)
    do {
      do {
        let snapshot = try service.importSnapshot(at: url)
        refreshDictionaries()
        return RimeLocalization.message("Imported snapshot into \((snapshot.dictionary ?? name)): \(url.lastPathComponent)")
      } catch RimeSyncError.notASnapshot {
        let count = try service.importExportFile(url, into: name)
        refreshDictionaries()
        return RimeLocalization.message("Imported \(String(count)) entries into \(name)")
      }
    } catch {
      errorMessage = RimeLocalization.message("Failed to import dictionary: \(String(describing: error))")
      return ""
    }
  }

  // MARK: - Notices (S6)

  func refreshNotices() async {
    let workspace = self.workspace
    let engine = self.engine
    let revision = configurationRevision
    let snapshot = await Task.detached(priority: .userInitiated) {
      RimeNoticesBuilder.build(workspace: workspace, engine: engine)
    }.value
    guard !Task.isCancelled else { return }
    if revision != configurationRevision {
      await refreshNotices()
      return
    }
    notices = snapshot
  }
}
