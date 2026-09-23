import Foundation
import SwiftUI
import RimeEngine
import UIKit

/// Reads the probe log the keyboard writes, so a failure on a device can be copied out of the
/// app instead of guessed at from a truncated line above the keys.
struct DiagnosticsView: View {
  @State private var records: [RimeProbeRecord] = []
  @State private var status = "读取中…"
  @State private var showingClearConfirmation = false

  var body: some View {
    List {
      Section("容器") {
        Text(status)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      if records.isEmpty {
        Section {
          Text("没有日志。先在设置里启用 Arkey 键盘、打开完全访问，敲几个键，再回到这里刷新。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      } else {
        Section("键盘日志（" + String(records.count) + " 条）") {
          ForEach(Array(records.enumerated()), id: \.offset) { _, record in
            VStack(alignment: .leading, spacing: 3) {
              Text(record.phase).font(.footnote.bold())
              Text(detail(record)).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .navigationTitle("诊断")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("刷新") { load() }
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("清理") { showingClearConfirmation = true }
          .disabled(logURL == nil)
        Button("复制") { copyAll() }
      }
    }
    .confirmationDialog("清理键盘日志？",
                        isPresented: $showingClearConfirmation,
                        titleVisibility: .visible) {
      Button("清理 " + String(records.count) + " 条记录", role: .destructive) { clear() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("清空整个日志目录：探针日志与 librime 自己的日志文件。键盘、词库和用户数据都不受影响，清空后无法恢复。")
    }
    .task { load() }
  }

  // MARK: - Log access

  private var logURL: URL? { ProbeLogLocation.groupLogURL }

  /// Truncates the probe log in place rather than replacing the file: the keyboard may be
  /// appending at the same moment, and an atomic write would swap the inode out from under it.
  /// librime's own glog files sit in the same directory and are cleared with it, so the container
  /// does not accumulate history either.
  private func clear() {
    guard let url = logURL else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      try? handle.truncate(atOffset: 0)
      try? handle.close()
    }
    let directory = url.deletingLastPathComponent()
    let contents = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)) ?? []
    for file in contents where file.lastPathComponent != url.lastPathComponent {
      try? FileManager.default.removeItem(at: file)
    }
    records = []
    load()
  }

  private func load() {
    guard let url = logURL else {
      status = "拿不到 App Group 容器：请在键盘设置里打开“允许完全访问”，然后重新打开键盘。"
      records = []
      return
    }
    records = RimeProbeLog(url: url).readAll()
    ProbeLogLocation.mirrorIntoAppContainer()
    status = records.isEmpty
      ? url.path + "（暂无记录）"
      : url.path
  }

  private func copyAll() {
    let lines = records.map(detail)
    UIPasteboard.general.string = lines.isEmpty
      ? status
      : status + "\n" + lines.joined(separator: "\n")
  }

  private func detail(_ record: RimeProbeRecord) -> String {
    var parts = [Self.time.string(from: record.timestamp)]
    if let milliseconds = record.milliseconds {
      parts.append(String(format: "%.1f ms", milliseconds))
    }
    if let bytes = record.footprintBytes, bytes > 0 {
      parts.append(String(format: "%.1f MB", RimeProbe.megabytes(bytes)))
    }
    if let message = record.message {
      parts.append(message)
    }
    return parts.joined(separator: "  ")
  }

  private static let time: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
}
