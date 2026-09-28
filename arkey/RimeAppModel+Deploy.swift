import Combine
import Foundation
import RimeEngine
import SwiftUI

/// S2 §6's 部署 screen: what the last deploy produced, librime's own log, and the two ways back —
/// redeploy, or roll back to the previous generation.
@MainActor
extension RimeAppModel {
  var deployLog: [RimeLogRecord] { engine.logBuffer.snapshot() }

  /// The newest settings backup, which is what "revert" restores. The engine writes one before any
  /// import and `RimePatch` writes one before a patch is touched.
  var latestSettingsBackup: URL? {
    let root = workspace.root.appendingPathComponent("backups", isDirectory: true)
    let entries = (try? FileManager.default.contentsOfDirectory(at: root,
                                                                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return entries
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .sorted { left, right in
        let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return l > r
      }
      .first
  }

  /// Deploys the active (or first) profile again from its sources, which is S2 §6's retry button and
  /// S1 §7's re-deploy.
  func redeployActiveProfile() async {
    guard let id = activeProfileID ?? profiles.first?.id else {
      errorMessage = "没有可部署的配置。"
      return
    }
    await deploy(profileID: id)
  }

  func rollbackActiveProfile() {
    guard let id = activeProfileID ?? profiles.first?.id else { return }
    rollback(profileID: id)
  }

  /// Copies the newest backup's files over the user directory: one action, as S2-AC4 asks.
  func restoreLatestSettingsBackup() async {
    guard let backup = latestSettingsBackup else {
      errorMessage = "还没有任何备份可恢复。"
      return
    }
    let files = (try? FileManager.default.contentsOfDirectory(at: backup,
                                                              includingPropertiesForKeys: nil)) ?? []
    do {
      for file in files {
        let target = workspace.userData.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
          try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: file, to: target)
      }
      await redeployActiveProfile()
      deployMessage = "已恢复 " + String(files.count) + " 个设置文件并重新部署。"
    } catch {
      errorMessage = "恢复备份失败：" + String(describing: error)
    }
  }
}
