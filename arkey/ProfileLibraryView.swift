import SwiftUI
import RimeEngine
import UniformTypeIdentifiers

/// The 配置库 screen: what is installed, what is deployed, and the one action that changes what the
/// keyboard types. Every write goes through the model, which owns the app's single engine.
struct ProfileLibraryView: View {
  @ObservedObject var model: RimeAppModel

  /// One picker per screen, not two. SwiftUI keeps a single presentation per view: with two fileImporters
  /// stacked on this List the toolbar's never presented at all — tapping 导入 did nothing, which is what
  /// round 189's UI test reproduced before this changed.
  private enum ImportKind: Identifiable {
    case profile
    case settings
    var id: Self { self }
  }
  @State private var importing: ImportKind?
  @State private var adoptUserData = false
  @State private var pendingDeletion: RimeAppModel.LibraryEntry?
  @State private var deleteDictionaries = false
  @State private var busyProfileID: String?
  @State private var exported: URL?

  var body: some View {
    List {
      activeSection
      installedSection
      SettingsDeployFooter(model: model)
      settingsSection
      if !model.importWarnings.isEmpty { warningsSection }
      if let error = model.errorMessage { errorSection(error) }
      storageSection
    }
    .navigationTitle("配置库")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          importing = .profile
        } label: {
          Label("导入", systemImage: "square.and.arrow.down")
        }
        .disabled(model.isDeploying)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("刷新") { model.refresh() }
      }
    }
    // The union of both kinds' types; the handler refuses what the kind does not accept, which is what a
    // second importer was standing in for.
    .fileImporter(isPresented: Binding(get: { importing != nil },
                                       set: { if !$0 { importing = nil } }),
                  allowedContentTypes: [.zip, .folder],
                  allowsMultipleSelection: false) { result in
      let kind = importing
      importing = nil
      switch kind {
      case .profile:
        handleImport(result)
      case .settings:
        handleSettingsImport(result)
      case nil:
        break
      }
    }
    .confirmationDialog("删除配置？",
                        isPresented: Binding(get: { pendingDeletion != nil },
                                             set: { if !$0 { pendingDeletion = nil } }),
                        titleVisibility: .visible,
                        presenting: pendingDeletion) { entry in
      Button("删除配置，保留用户词库", role: .destructive) {
        model.delete(profileID: entry.metadata.id)
        pendingDeletion = nil
      }
      Button("删除配置与用户词库", role: .destructive) {
        model.delete(profileID: entry.metadata.id, removingUserDictionaries: model.userDatabaseNames)
        pendingDeletion = nil
      }
      Button("取消", role: .cancel) { pendingDeletion = nil }
    } message: { entry in
      Text(dictionaryNote(for: entry))
    }
  }

  // MARK: Sections

  private var activeSection: some View {
    Section("当前生效") {
      VStack(alignment: .leading, spacing: 4) {
        Text(model.resolvedSummary).font(.body)
        Text("键盘在下次出现时采用这里的变化；正在输入的句子不会被切换打断。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Toggle("导入时同时采用用户设置（*.custom.yaml、custom_phrase.txt）", isOn: $adoptUserData)
        .font(.footnote)
    }
  }

  private var installedSection: some View {
    Section("已安装（" + String(model.libraryEntries.count) + "）") {
      if model.libraryEntries.isEmpty {
        Text("还没有配置。导入一个 zip 或文件夹（例如 rime-ice 的 full.zip，或 Mac 上 ~/Library/Rime 的副本）。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach(model.libraryEntries) { entry in
        row(entry)
      }
    }
  }

  private func row(_ entry: RimeAppModel.LibraryEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(entry.metadata.displayName).font(.body.weight(.medium))
        if entry.isActive {
          Text("生效中").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
        }
        if busyProfileID == entry.metadata.id { ProgressView().controlSize(.mini) }
      }
      Text(entry.metadata.id).font(.caption2).foregroundStyle(.secondary)
      Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button("部署") { deploy(entry) }
        Button("激活") { model.activate(profileID: entry.metadata.id) }
          .disabled(entry.isActive)
        if entry.metadata.deploy != nil {
          Button("回滚") { model.rollback(profileID: entry.metadata.id) }
        }
        Button("删除", role: .destructive) {
          deleteDictionaries = false
          pendingDeletion = entry
        }
      }
      .font(.caption)
      .buttonStyle(.borderless)
      .disabled(model.isDeploying)
    }
    .padding(.vertical, 2)
  }

  /// S2 §7: plain text the user can read, moved between devices without the third-party sources.
  private var settingsSection: some View {
    Section {
      if let exported {
        ShareLink(item: exported) { Text("分享导出的设置") }
      } else {
        Button("导出设置（补丁 + 自定义短语）") { exported = model.exportSettings() }
      }
      Button("导入设置…") { importing = .settings }
    } header: {
      Text("设置")
    } footer: {
      Text("导出的是 *.custom.yaml 与自定义短语，不含任何第三方配置数据；导入会先备份现有设置并自动重新部署。")
    }
  }

  private var warningsSection: some View {
    Section("导入结果") {
      ForEach(Array(model.importWarnings.enumerated()), id: \.offset) { _, warning in
        Text(warning).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func errorSection(_ message: String) -> some View {
    Section("错误") {
      Text(UserFacing.text(message)).font(.caption).foregroundStyle(.red)
      Button("清除") { model.errorMessage = nil }.font(.caption)
    }
  }

  private var storageSection: some View {
    Section("存储") {
      if let storage = model.storage {
        ForEach(storage.profiles, id: \.id) { profile in
          Text(profile.displayName + "：" + bytes(profile.sourceBytes + profile.buildBytes + profile.previousBuildBytes))
            .font(.caption)
        }
        Text("用户目录：" + bytes(storage.userDataBytes)).font(.caption)
        Text("合计：" + bytes(storage.totalBytes)).font(.caption).foregroundStyle(.secondary)
      } else {
        Text("（尚未统计）").font(.caption).foregroundStyle(.secondary)
      }
      Text(model.workspace.root.path).font(.caption2).foregroundStyle(.secondary)
    }
  }

  // MARK: Actions

  private func deploy(_ entry: RimeAppModel.LibraryEntry) {
    busyProfileID = entry.metadata.id
    Task {
      await model.deploy(profileID: entry.metadata.id)
      busyProfileID = nil
    }
  }

  private func handleImport(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      model.errorMessage = "选择文件失败：" + String(describing: error)
    case .success(let urls):
      guard let url = urls.first else { return }
      Task { await model.importPayload(at: url, displayName: nil, adoptUserData: adoptUserData) }
    }
  }

  /// The settings import takes a zip and nothing else, which the shared picker has to say for itself.
  private func handleSettingsImport(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      model.errorMessage = "选择文件失败：" + String(describing: error)
    case .success(let urls):
      guard let url = urls.first else { return }
      guard url.pathExtension.lowercased() == "zip" else {
        model.errorMessage = "导入设置需要导出设置生成的 zip 文件，选中的是 " + url.lastPathComponent + "。"
        return
      }
      Task { await model.importSettingsBundle(from: url) }
    }
  }

  private func dictionaryNote(for entry: RimeAppModel.LibraryEntry) -> String {
    let names = model.userDatabaseNames
    let base = "用户词库属于词库名而不是配置，删除配置默认会保留它们，这样换配置再换回来时学过的词还在。"
    return names.isEmpty ? base : base + " 当前有：" + names.joined(separator: "、")
  }

  private func detail(_ entry: RimeAppModel.LibraryEntry) -> String {
    var parts: [String] = []
    parts.append("方案 " + String(entry.metadata.stats.schemaIDs.count))
    parts.append("源 " + bytes(entry.metadata.stats.sourceBytes))
    parts.append("构建 " + bytes(entry.buildBytes))
    if let license = entry.metadata.license?.spdx { parts.append(license) }
    if let deploy = entry.metadata.deploy {
      parts.append("第 " + String(deploy.generation) + " 代")
      parts.append(String(format: "%.1f s", deploy.durationSeconds))
    } else {
      parts.append("未部署")
    }
    return parts.joined(separator: " · ")
  }

  /// The engine's one size format: this screen used to carry its own `ByteCountFormatter`, and the
  /// diagnostics screen a third style for the same number.
  private func bytes(_ value: Int) -> String {
    RimeProbe.formatted(bytes: UInt64(max(0, value)))
  }
}
