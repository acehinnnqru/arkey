import SwiftUI
import RimeEngine

/// S2 §6's 部署 screen: the last result, librime's own text, and the way back.
struct DeployView: View {
  @ObservedObject var model: RimeAppModel

  var body: some View {
    List {
      activeSection
      resultSection
      if !model.deployLog.isEmpty { logSection }
      actionsSection
      if let error = model.errorMessage { UserFacing.errorRow(error) }
    }
    .navigationTitle("部署")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("刷新") { model.refresh() }
      }
    }
  }

  private var activeSection: some View {
    Section("当前") {
      if let entry = model.libraryEntries.first(where: { $0.isActive }) {
        Text(entry.metadata.displayName).font(.body)
        if let deploy = entry.metadata.deploy {
          Text(summary(deploy))
            .font(.caption).foregroundStyle(.secondary)
          Text(deploy.deployedAt.formatted(date: .abbreviated, time: .standard))
            .font(.caption2).foregroundStyle(.secondary)
        }
      } else {
        Text("当前使用内置数据，没有部署的配置。")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  /// Built in steps rather than as one concatenation: as a single expression the type checker gives
  /// up on it, which is a compiler limit, not a design one.
  private func summary(_ deploy: RimeProfileDeployRecord) -> String {
    let duration = String(format: "%.1f s", deploy.durationSeconds)
    let parts = ["第 " + String(deploy.generation) + " 代", duration,
                 String(deploy.warnings.count) + " 条告警"]
    return parts.joined(separator: " · ")
  }

  private var resultSection: some View {
    Section("上一次部署") {
      if let message = model.deployMessage {
        // The sync-folder messages carry the folder's own path, and a container path is not a sentence about
        // anything the user can act on.
        Text(UserFacing.text(message)).font(.caption)
      } else {
        Text("还没有部署过。").font(.caption).foregroundStyle(.secondary)
      }
      if model.isDeploying {
        HStack(spacing: 8) { ProgressView(); Text("部署中…").font(.caption) }
      }
    }
  }

  private var logSection: some View {
    Section {
      // librime's own text, because a generic "deploy failed" tells nobody which file was wrong.
      ForEach(Array(model.deployLog.suffix(20).enumerated()), id: \.offset) { _, record in
        Text(record.display)
          .font(.caption2)
          .foregroundStyle(record.severity >= .error ? Color.red : Color.secondary)
      }
    } header: {
      Text("librime 日志（最近 20 条）")
    }
  }

  private var actionsSection: some View {
    Section {
      Button {
        Task { await model.redeployActiveProfile() }
      } label: {
        Text("重新部署")
      }
      .disabled(model.isDeploying)

      Button(role: .destructive) {
        model.rollbackActiveProfile()
      } label: {
        Text("回滚到上一代构建")
      }
      .disabled(model.isDeploying)

      Button {
        Task { await model.restoreLatestSettingsBackup() }
      } label: {
        Text("恢复上次设置备份并重新部署")
      }
      .disabled(model.isDeploying)
    } footer: {
      Text("部署只发生在 App 里，键盘从不在自己的路径上部署。回滚恢复 build.previous 并把 active.json 指回它；设置备份是导入或改写补丁前留下的那一份。")
    }
  }
}
