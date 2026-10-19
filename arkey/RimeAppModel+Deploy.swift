import Combine
import Foundation
import RimeEngine
import SwiftUI

/// A session-local attempt, kept separate from activation and settings-import messages.
struct DeploymentAttempt: Sendable {
  let id: UUID
  let profileID: String
  let profileName: String
  let startedAt: Date
  var finishedAt: Date?
  var message = RimeLocalization.message("Deploying…")
  var failed = false
  var wasInterrupted = false
  var logs: [RimeLogRecord] = []

  init(id: UUID = UUID(), profileID: String, profileName: String, startedAt: Date = Date()) {
    self.id = id
    self.profileID = profileID
    self.profileName = profileName
    self.startedAt = startedAt
  }
}

/// Deployment recovery actions shared by the profile library and settings writes.
@MainActor
extension RimeAppModel {
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
      errorMessage = RimeLocalization.message("No profile is available to deploy.")
      return
    }
    await deploy(profileID: id)
  }

  /// Copies the newest backup's files over the user directory: one action, as S2-AC4 asks.
  func restoreLatestSettingsBackup() async {
    guard let backup = latestSettingsBackup else {
      errorMessage = RimeLocalization.message("No backups are available to restore.")
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
      deployMessage = RimeLocalization.message("Restored \(String(files.count)) settings files and redeployed.")
      settingsFooter = .applied(RimeLocalization.message("Restored \(String(files.count)) settings files"))
    } catch {
      errorMessage = RimeLocalization.message("Failed to restore backup: \(String(describing: error))")
    }
  }
}
