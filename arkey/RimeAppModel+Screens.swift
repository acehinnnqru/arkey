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

  /// Which schema the settings screens are editing: the deployed one if there is one, the first
  /// otherwise.
  var settingsSchemaID: String? {
    if let current = try? engine.currentSchema(), !current.isEmpty { return current }
    return schemas.first
  }

  func refreshSettings() {
    schemas = (try? engine.schemaIDs()) ?? []
    schemaOrderIDs = schemaOrder
    let enabled = schemaOrderIDs
    let offered = (try? schemaListEditor().available()) ?? installedSchemaIDs
    schemaRows = offered + enabled.filter { !offered.contains($0) }
    guard let id = settingsSchemaID else {
      schemaDescriptor = nil
      return
    }
    do {
      schemaDescriptor = try RimeSettingsModel.describeSchema(id, engine: engine)
    } catch {
      schemaDescriptor = nil
      errorMessage = "读取方案设置失败：" + String(describing: error)
    }
  }

  /// Writes one setting as a patch and redeploys, which is the only path S2 allows: shipped sources
  /// are read-only and a change reaches the keyboard through a deploy.
  func setSetting(_ descriptor: RimeSettingDescriptor, value: RimeSettingDescriptor.Value) async {
    guard let id = settingsSchemaID else { return }
    let patch = RimePatch(engine: engine, configID: configID(for: descriptor.scope, schemaID: id))
    do {
      switch value {
      case .boolean(let raw): _ = try patch.set(.bool(raw), at: descriptor.key)
      case .integer(let raw): _ = try patch.set(.int(raw), at: descriptor.key)
      case .text(let raw): _ = try patch.set(.string(raw), at: descriptor.key)
      case .list(let raw): _ = try patch.set(.list(raw.map { .string($0) }), at: descriptor.key)
      }
      await deploy(profileID: activeProfileID ?? "")
      refreshSettings()
    } catch {
      errorMessage = "写入设置失败：" + String(describing: error)
    }
  }

  /// Reset deletes the key from the patch, so the schema's own value comes back (S2 §4).
  func resetSetting(_ descriptor: RimeSettingDescriptor) async {
    guard let id = settingsSchemaID else { return }
    let patch = RimePatch(engine: engine, configID: configID(for: descriptor.scope, schemaID: id))
    do {
      _ = try patch.remove(key: descriptor.key)
      await deploy(profileID: activeProfileID ?? "")
      refreshSettings()
    } catch {
      errorMessage = "重置失败：" + String(describing: error)
    }
  }

  /// A switch default is the whole list, not an index (measured: patching `switches/@N/reset` replaces
  /// the list and leaves one nameless entry).
  func setSwitch(_ name: String, reset: Int) async {
    guard let id = settingsSchemaID else { return }
    do {
      _ = try RimeSettingsModel.setSwitchReset(reset, forSwitch: name, schemaID: id, engine: engine)
      await deploy(profileID: activeProfileID ?? "")
      refreshSettings()
    } catch {
      errorMessage = "写入开关失败：" + String(describing: error)
    }
  }

  /// 模糊音 is composed into `speller/algebra` from the schema's own algebra, never appended (S2 §2.1).
  func setFuzzyPinyin(_ enabled: [String]) async {
    guard let id = settingsSchemaID else { return }
    do {
      let base = (try engine.schemaValue("speller/algebra", schemaID: id)?.listValue ?? [])
        .compactMap(\.stringValue)
      let composed = RimeFuzzyPinyin.compose(baseAlgebra: base, enabled: enabled)
      let patch = RimePatch(engine: engine, configID: id)
      _ = try patch.set(.list(composed.map { .string($0) }), at: "speller/algebra")
      await deploy(profileID: activeProfileID ?? "")
      refreshSettings()
    } catch {
      errorMessage = "写入模糊音失败：" + String(describing: error)
    }
  }

  var enabledFuzzyPresets: [String] {
    guard let id = settingsSchemaID,
          let algebra = try? engine.schemaValue("speller/algebra", schemaID: id)?.listValue
    else { return [] }
    return RimeFuzzyPinyin.enabledPresets(in: algebra.compactMap(\.stringValue))
  }

  // MARK: - Schema list (S2 §3, 方案)

  /// The schemas the active profile ships, enabled or not. librime's own list names only the enabled
  /// ones, so the ones that are off are read from the profile's sources.
  var installedSchemaIDs: [String] {
    guard let id = activeProfileID ?? profiles.first?.id else { return [] }
    return (try? RimeTreeClassifier.classify(root: workspace.profile(id).source).schemaIDs) ?? []
  }

  /// The enabled schemas, in the order the keyboard offers them; the first is the default (S2 §3).
  var schemaOrder: [String] {
    (try? schemaListEditor().effective()) ?? []
  }

  /// Enable, order and default are the same key, so they are the same write.
  func setSchemaList(_ ids: [String]) async {
    do {
      _ = try schemaListEditor().write(ids)
      await deploy(profileID: activeProfileID ?? "")
      refreshSettings()
    } catch {
      errorMessage = "写入方案列表失败：" + String(describing: error)
    }
  }

  func moveSchema(_ id: String, by offset: Int) async {
    var ids = schemaOrder
    guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
    ids.swapAt(index, index + offset)
    await setSchemaList(ids)
  }

  func setSchemaDefault(_ id: String) async {
    var ids = schemaOrder
    guard ids.contains(id), ids.first != id else { return }
    ids.removeAll { $0 == id }
    ids.insert(id, at: 0)
    await setSchemaList(ids)
  }

  func setSchema(_ id: String, enabled: Bool) async {
    var ids = schemaOrder
    if enabled {
      guard !ids.contains(id) else { return }
      ids.append(id)
    } else {
      guard ids.contains(id) else { return }
      ids.removeAll { $0 == id }
    }
    await setSchemaList(ids)
  }

  private func schemaListEditor() -> RimeSchemaListEditor {
    RimeSchemaListEditor(engine: engine, installed: installedSchemaIDs)
  }

  private func configID(for scope: RimeSettingDescriptor.Scope, schemaID: String) -> String {
    if case .schema(let id) = scope { return id }
    return "default"
  }

  // MARK: - User dictionary (S5)

  func refreshDictionaries() {
    let service = RimeSyncService(workspace: workspace, engine: engine)
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
  func mergeDictionaries() async {
    guard !isSyncing else { return }
    isSyncing = true
    let service = RimeSyncService(workspace: workspace, engine: engine)
    do {
      let outcome = try service.mergeFromOtherDevices()
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
