import Combine
import Foundation
import RimeEngine
import SwiftUI

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

  /// Reads the configuration back into the state the 方案 screen draws.
  ///
  /// Called when the screen opens, by its 刷新 button, and after every settings write — never from a body
  /// pass. Every read here is a synchronous call on the engine's queue, and a deploy holds that queue for its
  /// whole duration, so a body pass that made one would freeze the screen for the length of that deploy. That
  /// is the half of the reported 方案的开关特别卡 that has nothing to do with the switch itself.
  ///
  /// A choice that has been made and not deployed yet is laid back over that answer: it is what the user last
  /// said, the footer says it is waiting, and without it a redraw in the middle of a deploy would put the
  /// control back where the engine still is.
  func refreshSettings() {
    // Every read below is a synchronous call on the engine's queue, and a deploy holds that queue for its whole
    // duration — so a read asked for while one runs waits for it, on the main actor. That is the freeze the 方案
    // switches were reported as, and it is reachable without touching a switch: the screen's own `.task` runs
    // when it is entered, and 刷新 is a button. The values would be out of date by the time the deploy ended in
    // any case, so the screen keeps what it has and the deploy that refused the read hands it the answer.
    guard deployInFlight == nil else {
      settingsRefreshDeferred = true
      return
    }
    settingsRefreshDeferred = false

    schemas = (try? engine.schemaIDs()) ?? []
    let editor = schemaListEditor()
    let deployedOrder = (try? editor.effective()) ?? []
    let offered = (try? editor.available()) ?? installedSchemaIDs
    schemaRows = offered + deployedOrder.filter { !offered.contains($0) }

    var descriptor: RimeSchemaDescriptor?
    let schemaID = settingsSchemaID
    if let schemaID {
      do {
        descriptor = try RimeSettingsModel.describeSchema(schemaID, engine: engine)
      } catch {
        descriptor = nil
        errorMessage = "读取方案设置失败：" + String(describing: error)
      }
    }

    // The queue is the overlay, so the two cannot disagree: what is queued is exactly what is not deployed.
    var order = deployedOrder
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
      }
    }

    schemaDescriptor = descriptor
    schemaOrderIDs = order
    enabledFuzzyPresets = fuzzy ?? deployedFuzzyPresets(schemaID: schemaID)
  }

  /// The presets the deployed algebra carries, so the screen can show the state it wrote.
  private func deployedFuzzyPresets(schemaID: String?) -> [String] {
    guard let schemaID,
          let algebra = try? engine.schemaValue("speller/algebra", schemaID: schemaID)?.listValue
    else { return [] }
    return RimeFuzzyPinyin.enabledPresets(in: algebra.compactMap(\.stringValue))
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

  /// Enable, order and default are the same key, so they are the same write (S2 §3).
  ///
  /// The switch moves here and the write follows it. That order is the whole fix for the reported freeze: a
  /// switch whose value came from the *deployed* list could not move until the deploy ended, and a write made
  /// on the tap waited on the engine's queue, which is what that deploy was holding.
  func setSchemaList(_ ids: [String]) {
    guard ids != schemaOrderIDs else { return }
    schemaOrderIDs = ids
    enqueueSettingsWrite(.schemaList(ids))
  }

  func moveSchema(_ id: String, by offset: Int) {
    var ids = schemaOrderIDs
    guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
    ids.swapAt(index, index + offset)
    setSchemaList(ids)
  }

  func setSchemaDefault(_ id: String) {
    var ids = schemaOrderIDs
    guard ids.contains(id), ids.first != id else { return }
    ids.removeAll { $0 == id }
    ids.insert(id, at: 0)
    setSchemaList(ids)
  }

  func setSchema(_ id: String, enabled: Bool) {
    var ids = schemaOrderIDs
    if enabled {
      guard !ids.contains(id) else { return }
      ids.append(id)
    } else {
      guard ids.contains(id) else { return }
      ids.removeAll { $0 == id }
    }
    setSchemaList(ids)
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
    let service = RimeSyncService(workspace: workspace, engine: engine)
    syncChoice = workspace.loadSyncChoice()
    do {
      let report = try service.report()
      dictionaryReport = report
      dictionaryBackups = Dictionary(uniqueKeysWithValues: report.dictionaries.map { entry in
        (entry.name, service.backups(for: entry.name))
      })
    } catch {
      dictionaryReport = nil
      dictionaryBackups = [:]
      errorMessage = "读取用户词库失败：" + String(describing: error)
    }
  }

  /// S5 §4/§5: one backup on demand, beside the snapshot and pruned to the last three.
  func backupDictionary(_ name: String) {
    do {
      let service = RimeSyncService(workspace: workspace, engine: engine)
      guard try service.backup(dictionary: name) != nil else {
        errorMessage = "备份失败：同步目录里还没有这个词库的快照，librime 也没能写出一份。"
        return
      }
      syncMessage = "已备份 " + name
      refreshDictionaries()
    } catch {
      errorMessage = "备份失败：" + String(describing: error)
    }
  }

  /// Restores a backup through librime's own door. The file is the snapshot format, which is what
  /// `restore_user_dict` reads; the levers export would be recorded as spellings instead (S5 §5).
  func restoreDictionary(_ name: String, from url: URL) {
    do {
      let access = RimeDictionaryAccess(workspace: workspace, engine: engine)
      _ = try access.perform { try engine.restoreUserDictionary(snapshotFile: url) }
      syncMessage = "已从 " + url.lastPathComponent + " 恢复 " + name
      refreshDictionaries()
    } catch {
      errorMessage = "恢复失败：" + String(describing: error)
    }
  }

  func syncDictionaries() async {
    guard !isSyncing else { return }
    isSyncing = true
    syncMessage = "正在同步…"
    let service = RimeSyncService(workspace: workspace, engine: engine)
    do {
      let outcome = try service.syncNow()
      syncMessage = outcome.succeeded
        ? "同步完成：" + String(outcome.snapshots.count) + " 个快照，"
          + String(format: "%.1f s", outcome.duration)
        : "同步失败：" + (outcome.failureReason ?? "")
    } catch {
      syncMessage = "同步失败：" + String(describing: error)
      errorMessage = syncMessage
    }
    isSyncing = false
    refreshDictionaries()
  }

  /// S5 §6/§10: read every other device's snapshot in the shared folder and merge it in additively.
  /// The engine converts each one to the levers format first, because `restore_user_dict` would
  /// replace this device's words with the other device's instead of joining them.
  func mergeDictionaries(from deviceID: String? = nil) async {
    guard !isSyncing else { return }
    isSyncing = true
    let service = RimeSyncService(workspace: workspace, engine: engine)
    do {
      let outcome = try service.mergeFromOtherDevices(devices: deviceID.map { [$0] })
      if outcome.isEmpty {
        syncMessage = "同步目录里还没有其他设备的快照。"
      } else {
        let devices = Set(outcome.entries.flatMap(\.deviceIDs)).sorted().joined(separator: "、")
        let read = outcome.entries.reduce(0) { $0 + $1.entriesRead }
        syncMessage = "已从 " + devices + " 合并 " + String(outcome.entries.count)
          + " 个词库：读取 " + String(read) + " 条，并入 "
          + String(outcome.totalImported) + " 条"
      }
    } catch {
      syncMessage = "合并失败：" + String(describing: error)
      errorMessage = syncMessage
    }
    isSyncing = false
    refreshDictionaries()
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
      deployMessage = "同步文件夹已改为 " + validated.path
      settingsFooter = .applied("同步文件夹已更新")
      refreshDictionaries()
    } catch {
      errorMessage = "选择同步文件夹失败：" + String(describing: error)
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
      deployMessage = "同步文件夹已回到默认：" + fallback.path
      settingsFooter = .applied("同步文件夹已更新")
      refreshDictionaries()
    } catch {
      errorMessage = "恢复默认同步文件夹失败：" + String(describing: error)
    }
  }

  /// Removes a dictionary entirely. This is the deletion librime's levers API leaves us: import is
  /// additive, so a single word is forgotten from the keyboard's candidate bar (S4 §8), not here.
  func removeDictionary(_ name: String) {
    do {
      let editor = RimeDictionaryEditor(workspace: workspace, engine: engine)
      _ = try editor.removeDictionary(name)
      refreshDictionaries()
    } catch {
      errorMessage = "删除词库失败：" + String(describing: error)
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
      errorMessage = "导出失败：" + String(describing: error)
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
      errorMessage = "导出快照失败：" + String(describing: error)
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
      syncMessage = "已导出 " + String(export.dictionaries.count) + " 个词库快照（"
        + RimeProbe.formatted(bytes: UInt64(export.bytes)) + "）"
      return url
    } catch {
      errorMessage = "导出整组快照失败：" + String(describing: error)
      return nil
    }
  }

  /// S5 §5's "Import from Files": a Squirrel snapshot or this app's own levers export, told apart by shape
  /// rather than by which button was pressed. The engine backs the dictionary up before the import (S5-AC3),
  /// and the access gate refuses while the keyboard holds the lease. Returns the sentence to show, or "" when
  /// it failed — the error is on `errorMessage` then.
  func importDictionary(from url: URL, into name: String) -> String {
    let service = RimeSyncService(workspace: workspace, engine: engine)
    do {
      do {
        let snapshot = try service.importSnapshot(at: url)
        refreshDictionaries()
        return "已导入快照到 " + (snapshot.dictionary ?? name) + "：" + url.lastPathComponent
      } catch RimeSyncError.notASnapshot {
        let count = try service.importExportFile(url, into: name)
        refreshDictionaries()
        return "已导入 " + String(count) + " 条到 " + name
      }
    } catch {
      errorMessage = "导入词库失败：" + String(describing: error)
      return ""
    }
  }

  // MARK: - Notices (S6)

  func refreshNotices() {
    notices = RimeNoticesBuilder.build(workspace: workspace, engine: engine)
  }
}
