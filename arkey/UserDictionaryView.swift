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
  /// S5 §5: the dictionary whose row asked for an import, and the file picker's state.
  @State private var pendingImport: String?
  @State private var isImporting = false
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
      if let error = model.errorMessage { Section("错误") { Text(error).font(.caption).foregroundStyle(.red) } }
    }
    .navigationTitle("用户词库")
    .searchable(text: $query, prompt: "按词库名搜索")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("刷新") { model.refreshDictionaries() }
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
    .task { model.refreshDictionaries() }
    // S5 §5: the file the user picks is a snapshot or a levers export, and the engine tells them apart.
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
      guard let name = pendingImport, case .success(let url) = result else { return }
      importMessage = model.importDictionary(from: url, into: name)
    }
  }

  private func row(_ entry: RimeUserDictionaryReport.Entry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.name).font(.body.weight(.medium))
      Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
      if !entry.otherDeviceIDs.isEmpty {
        Text("其他设备：" + entry.otherDeviceIDs.joined(separator: "、"))
          .font(.caption2).foregroundStyle(.secondary)
      }
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
          isImporting = true
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
          }
        }
      }
    }
  }

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
      if !report.isLeaseCold {
        Text("键盘正在使用词库，所以现在不能同步。关掉键盘后再试。")
          .font(.caption).foregroundStyle(.orange)
      }
      if let directory = report.syncDirectory {
        Text(directory).font(.caption2).foregroundStyle(.secondary)
      } else {
        Text("尚未播种同步目录").font(.caption2).foregroundStyle(.secondary)
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
