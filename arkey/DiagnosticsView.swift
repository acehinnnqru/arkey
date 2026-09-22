import Foundation
import SwiftUI
import RimeEngine
import UIKit

/// The app group container is the only channel between the keyboard process and this one, and
/// it exists only when the user grants full access.
private let appGroupID = "group.com.acehinnnqru.arkey"

/// Reads the probe log the keyboard writes, so a failure on a device can be copied out of the
/// app instead of guessed at from a truncated line above the keys.
struct DiagnosticsView: View {
  @State private var records: [RimeProbeRecord] = []
  @State private var status = "读取中…"

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
      ToolbarItem(placement: .topBarTrailing) {
        Button("复制") { copyAll() }
      }
    }
    .task { load() }
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

  private func load() {
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
      status = "拿不到 App Group 容器：请在键盘设置里打开“允许完全访问”，然后重新打开键盘。"
      records = []
      return
    }
    let url = container.appendingPathComponent("rime/log/probe.jsonl")
    records = RimeProbeLog(url: url).readAll()
    status = url.path
  }

  private func copyAll() {
    let lines = records.map(detail)
    UIPasteboard.general.string = lines.isEmpty ? status : status + "\n" + lines.joined(separator: "\n")
  }
}
