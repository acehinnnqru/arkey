import SwiftUI
import UniformTypeIdentifiers
import RimeEngine

/// S5's 用户词库 screen. Every action states whether it can run: the keyboard holds the dictionaries
/// while it is on screen, and librime does not report the second opener — it hands back a dictionary
/// that is silently not loaded, which is why this refuses instead.
struct UserDictionaryView: View {
  @ObservedObject var model: RimeAppModel
  @State private var exported: URL?
  /// S5 §5: the snapshot a Squirrel user imports, as opposed to the levers export this app reads back.
  @State private var exportedSnapshot: URL?
  /// S5 §5's other export: every dictionary's snapshot in one zip.
  @State private var exportedSet: URL?
  /// S5 §5: the dictionary whose row asked for an import, and the file picker's state.
  @State private var pendingImport: String?
  /// One picker per screen: two fileImporters on this List meant neither presented (round 189 — the same
  /// defect the profile library had).
  ///
  /// The kind is set before the picker is presented and the dismissal does not clear it: held in the
  /// optional the presentation binding clears, it read as `nil` in the completion handler and both branches
  /// — the dictionary import and the sync folder — were skipped in silence (round 190).
  private enum Pick {
    case dictionary
    case syncFolder
  }
  @State private var isPicking = false
  @State private var pick: Pick = .dictionary
  @State private var importMessage = ""
  @State private var pendingRemoval: String?
  @State private var query = ""

  var body: some View {
    List {
      if let report = model.dictionaryReport {
        // S5-AC6: learning off is an explanation, not an error.
        if let reason = model.syncDisabledReason {
          Section {
            Text(reason).font(.caption).foregroundStyle(.orange)
          }
        }
        let matching = model.filteredDictionaries(matching: query)
        if report.dictionaries.isEmpty {
          Section {
            Text("还没有用户词库。装上键盘、打开完全访问，打几个词就有了。")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        } else if matching.isEmpty {
          Section { Text("没有匹配「" + query + "」的词库。").font(.footnote).foregroundStyle(.secondary) }
        } else {
          Section("词库（" + String(matching.count) + "）") {
            ForEach(matching, id: \.name) { entry in
              row(entry)
            }
          }
        }
        backupsSection(report)
        syncSection(report)
      } else {
        Section { Text("读取中…").font(.footnote) }
      }
      if let message = model.syncMessage { Section("同步") { Text(message).font(.caption) } }
      if let error = model.errorMessage { UserFacing.errorRow(error) }
    }
    .navigationTitle("用户词库")
    .searchable(text: $query, prompt: "按词库名搜索")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("刷新") { Task { await model.refreshDictionariesInBackground() } }
      }
    }
    .confirmationDialog("清空这个词库？",
                        isPresented: Binding(get: { pendingRemoval != nil },
                                             set: { if !$0 { pendingRemoval = nil } }),
                        titleVisibility: .visible) {
      Button("清空并删除", role: .destructive) {
        if let name = pendingRemoval { model.removeDictionary(name) }
        pendingRemoval = nil
      }
      Button("取消", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("整表删除，无法恢复；若要只忘掉某一个词，请在键盘的候选上长按删除（桌面端的 Shift+Delete）。"
           + "librime 的导入是增量写入，删掉一行再导回去并不会移除词条。")
    }
    .task { await model.refreshDictionariesInBackground() }
    // S5 §5: the file the user picks is a snapshot or a levers export, and the engine tells them apart. The
    // types are the union of both kinds; each branch keeps to its own.
    .fileImporter(isPresented: $isPicking,
                  allowedContentTypes: [.item, .folder]) { result in
      switch (pick, result) {
      case (.dictionary, .success(let url)):
        guard let name = pendingImport else { return }
        importMessage = model.importDictionary(from: url, into: name)
      case (.dictionary, .failure(let error)):
        model.errorMessage = "选择文件失败：" + String(describing: error)
      case (.syncFolder, .success(let url)):
        model.chooseSyncFolder(url)
      case (.syncFolder, .failure(let error)):
        model.errorMessage = "选择文件夹失败：" + String(describing: error)
      }
    }
  }

  private func row(_ entry: RimeUserDictionaryReport.Entry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.name).font(.body.weight(.medium))
      Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
      if entry.isDamaged {
        VStack(alignment: .leading, spacing: 2) {
          Text("librime 打不开词库「" + entry.name + "」，已就地重建为空库；写入也会失败。"
               + "用下面的备份恢复，或从其他设备快照合并。")
            .font(.caption2).foregroundStyle(.orange)
          ForEach(entry.databaseIssues, id: \.message) { issue in
            Text((issue.isReadOnly ? "只读：" : "损坏：") + issue.message)
              .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
          }
        }
      }
      otherDeviceRows(entry)
      if entry.conflictCopies > 0 {
        Text("有 " + String(entry.conflictCopies) + " 个 iCloud 冲突副本，会一并读取")
          .font(.caption2).foregroundStyle(.orange)
      }
      HStack(spacing: 12) {
        Button("导出（levers 格式，Squirrel 不读）") {
          exported = model.exportDictionary(entry.name)
        }
        Button("导出快照（Squirrel 可读）") {
          exportedSnapshot = model.exportSnapshot(entry.name)
        }
        Button("导入…") {
          pendingImport = entry.name
          pick = .dictionary
          isPicking = true
        }
        Button("备份") { model.backupDictionary(entry.name) }
        if let snapshot = exportedSnapshot {
          ShareLink(item: snapshot) { Text("分享快照") }.font(.caption)
        }
        Button("清空该词库", role: .destructive) {
          pendingRemoval = entry.name
        }
      }
      .font(.caption)
      .disabled(model.isSyncing)
    }
    .padding(.vertical, 2)
  }

  /// S5 §4/§5: the backups the app keeps beside the snapshots. Restoring one is the undo for an
  /// import that brought in something unwanted; the section says how many are kept so nobody expects
  /// an unbounded history.
  @ViewBuilder
  private func backupsSection(_ report: RimeUserDictionaryReport) -> some View {
    let files = report.dictionaries.flatMap { entry in
      (model.dictionaryBackups[entry.name] ?? []).map { (name: entry.name, url: $0) }
    }
    if !files.isEmpty {
      Section("备份（每个词库保留最近三份）") {
        ForEach(files, id: \.url) { file in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(file.name).font(.caption)
              Text(file.url.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("恢复") { model.restoreDictionary(file.name, from: file.url) }
              .font(.caption)
              .disabled(model.isSyncing)
          }
        }
      }
    }
  }

  /// S5 §9: the other devices appear as separate sources, each with when its snapshot was taken, so
  /// the user can merge one and ignore another instead of taking whatever the folder happens to hold.
  @ViewBuilder
  private func otherDeviceRows(_ entry: RimeUserDictionaryReport.Entry) -> some View {
    ForEach(entry.otherDevices, id: \.deviceID) { device in
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("其他设备 " + device.deviceID).font(.caption2)
          Text(Self.stamp.string(from: device.modifiedAt) + " · " + bytes(device.bytes)
               + (device.isConflictCopy ? " · iCloud 冲突副本" : ""))
            .font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button("合并") { Task { await model.mergeDictionaries(from: device.deviceID) } }
          .font(.caption2)
          .buttonStyle(.borderless)
          .disabled(model.isSyncing)
      }
    }
  }

  private static let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()

  private func syncSection(_ report: RimeUserDictionaryReport) -> some View {
    Section("同步") {
      Button {
        Task { await model.syncDictionaries() }
      } label: {
        HStack {
          Text("立即同步")
          if model.isSyncing { Spacer(); ProgressView() }
        }
      }
      .disabled(model.isSyncing || !report.isLeaseCold || model.syncDisabledReason != nil)
      Button {
        Task { await model.mergeDictionaries() }
      } label: {
        HStack {
          Text("合并其他设备")
          if model.isSyncing { Spacer(); ProgressView() }
        }
      }
      .disabled(model.isSyncing || !report.isLeaseCold || model.syncDisabledReason != nil)
      Text("读取共享目录里其他设备的快照，增量并入本机词库；合并前会先备份。")
        .font(.caption2).foregroundStyle(.secondary)
      if let leaseReason = report.leaseBlocker {
        // The engine's own sentence: a live keyboard and an unreadable lease file are different
        // situations, and the screen should not describe one as the other.
        Text(leaseReason.description)
          .font(.caption).foregroundStyle(.orange)
      }
      if let set = exportedSet {
        ShareLink(item: set) { Text("分享整组快照（zip）") }.font(.caption)
      } else {
        Button("导出整组快照（zip）") { exportedSet = model.exportAllDictionaries() }
          .font(.caption)
          .disabled(model.isSyncing)
      }
      if let directory = report.syncDirectory {
        Text(UserFacing.text(directory)).font(.caption2).foregroundStyle(.secondary)
      } else {
        Text("尚未播种同步目录").font(.caption2).foregroundStyle(.secondary)
      }
      // S5 §6's alternative: a folder the user picked, held as a bookmark, validated when it changes.
      if let choice = model.syncChoice {
        Text("自定义文件夹（" + Self.stamp.string(from: choice.chosenAt) + "选择）")
          .font(.caption2).foregroundStyle(.secondary)
        Button("恢复默认（iCloud / 文稿）") { model.useDefaultSyncFolder() }
          .font(.caption)
          .disabled(model.isSyncing)
      } else {
        Button("选择同步文件夹…") {
          pick = .syncFolder
          isPicking = true
        }
          .font(.caption)
          .disabled(model.isSyncing)
      }
      if let problem = model.syncChoiceProblem {
        Text(problem).font(.caption2).foregroundStyle(.orange)
      }
      if let id = report.installationID {
        Text("installation_id " + id).font(.caption2).foregroundStyle(.secondary)
      }
      Text("词库属于词库名而不是配置：换配置再换回来，学过的词还在。")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func detail(_ entry: RimeUserDictionaryReport.Entry) -> String {
    var parts = [bytes(entry.databaseBytes)]
    parts.append(String(entry.entryCount) + " 条")
    if entry.localSnapshotBytes > 0 { parts.append("本机快照 " + bytes(entry.localSnapshotBytes)) }
    if !entry.isLearned { parts.append("尚未学词") }
    return parts.joined(separator: " · ")
  }

  /// The engine's one size format: this screen used to carry its own `ByteCountFormatter`, and the
  /// diagnostics screen a third style for the same number.
  private func bytes(_ value: Int) -> String {
    RimeProbe.formatted(bytes: UInt64(max(0, value)))
  }
}
