import Foundation
import SwiftUI
import RimeEngine
import UIKit

/// Reads the probe log the keyboard writes, so a failure on a device can be copied out of the
/// app instead of guessed at from a truncated line above the keys.
struct DiagnosticsView: View {
  @StateObject private var model = RimeAppModel.shared
  @State private var records: [RimeProbeRecord] = []
  @State private var status = "读取中…"
  @State private var showingClearConfirmation = false

  var body: some View {
    List {
      Section("配置") {
        // S1 §9: every degraded mode names the exact path this process resolves.
        Text(model.resolvedSummary).font(.footnote)
        if let resolved = model.resolved {
          Text("shared  " + resolved.directories.sharedDataDir)
            .font(.caption2).foregroundStyle(.secondary)
          Text("prebuilt  " + resolved.directories.prebuiltDataDir)
            .font(.caption2).foregroundStyle(.secondary)
          Text("user  " + resolved.directories.userDataDir)
            .font(.caption2).foregroundStyle(.secondary)
        }
        Text(model.engineStatus).font(.caption).foregroundStyle(.secondary)
        Text("已安装配置 " + String(model.profiles.count) + " 个")
          .font(.caption).foregroundStyle(.secondary)
      }

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
        // S1-AC8 and S4-AC6: the numbers first, because that is what the acceptance criteria read, and
        // the raw lines under them for the case the numbers do not explain.
        Section("统计") {
          ForEach(RimeProbeSummary(records: records).orderedPhases, id: \.name) { phase in
            VStack(alignment: .leading, spacing: 2) {
              Text(phase.name).font(.footnote.bold())
              Text(summaryLine(phase)).font(.caption).foregroundStyle(.secondary)
            }
          }
        }

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
    // The numbers first, then the evidence they came from: one paste carries both, which is what a device
    // run needs when it leaves the phone (S1-AC8, S4-AC6).
    let lines = records.map(detail)
    guard !lines.isEmpty else {
      UIPasteboard.general.string = status
      return
    }
    UIPasteboard.general.string = status + "\n\n"
      + RimeProbeSummary(records: records).report()
      + "\n\n— 原始记录 —\n" + lines.joined(separator: "\n")
  }

  /// One phase as a line: how many samples, and the numbers a reader compares against the spec.
  private func summaryLine(_ phase: RimeProbeSummary.Phase) -> String {
    var parts = [String(phase.count) + " 次"]
    if let median = phase.medianMilliseconds {
      parts.append("中位 " + String(format: "%.1f", median) + " ms")
    }
    if let p95 = phase.p95Milliseconds {
      parts.append("p95 " + String(format: "%.1f", p95) + " ms")
    }
    if let worst = phase.maxMilliseconds {
      parts.append("最差 " + String(format: "%.1f", worst) + " ms")
    }
    if let bytes = phase.lastFootprintBytes {
      parts.append("占用 " + RimeProbe.formatted(bytes: bytes))
    }
    if let bytes = phase.maxFootprintBytes, bytes != phase.lastFootprintBytes {
      parts.append("峰值 " + RimeProbe.formatted(bytes: bytes))
    }
    if let message = phase.lastMessage {
      parts.append(message)
    }
    return parts.joined(separator: " · ")
  }

  private func detail(_ record: RimeProbeRecord) -> String {
    var parts = [Self.time.string(from: record.timestamp)]
    if let milliseconds = record.milliseconds {
      parts.append(String(format: "%.1f ms", milliseconds))
    }
    if let bytes = record.footprintBytes, bytes > 0 {
      parts.append(RimeProbe.formatted(bytes: bytes))
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
