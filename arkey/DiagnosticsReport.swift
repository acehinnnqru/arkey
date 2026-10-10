import Foundation
import RimeEngine

enum DiagnosticsReport {
  /// Fold older per-frame traces for display/export without deleting the raw log.
  static func compact(_ records: [RimeProbeRecord]) -> [RimeProbeRecord] {
    var result: [RimeProbeRecord] = []
    var legacy: [String: (count: Int, first: RimeProbeRecord, last: RimeProbeRecord)] = [:]
    for record in records {
      guard record.phase.hasPrefix("keyboard.geometry."),
            record.phase != "keyboard.geometry.summary", record.phase != "keyboard.geometry.legacySummary",
            let message = record.message else {
        result.append(record)
        continue
      }
      let tokens = message.split(separator: " ")
      guard let id = tokens.first(where: { $0.hasPrefix("id=") }),
            let appearance = tokens.first(where: { $0.hasPrefix("appearance=") }) else {
        result.append(record)
        continue
      }
      let key = String(id) + "/" + appearance
      if var group = legacy[key] {
        group.count += 1
        group.last = record
        legacy[key] = group
      } else {
        legacy[key] = (1, record, record)
      }
    }
    for group in legacy.values {
      var record = group.last
      record.phase = "keyboard.geometry.legacySummary"
      record.message = "Legacy trace: \(group.count) records\nfirst: \(group.first.message ?? "")"
        + (group.count > 1 ? "\nlast: \(group.last.message ?? "")" : "")
      result.append(record)
    }
    return Array(result.sorted { $0.timestamp < $1.timestamp }.suffix(80))
  }

  static func text(records: [RimeProbeRecord], location: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    var lines: [String] = []
    var length = 0
    // Prefer recent evidence and bound the pasteboard payload, including legacy logs.
    for record in records.reversed() {
      let message = record.message ?? ""
      let excerpt = String(message.prefix(12_000)) + (message.count > 12_000 ? "\n[Message truncated]" : "")
      let line = formatter.string(from: record.timestamp) + " " + record.phase + "\n" + excerpt
      guard length + line.utf8.count <= 128_000 else { break }
      lines.append(line)
      length += line.utf8.count
    }
    let header = "Arkey diagnostics\napp \(RimeHostVersion.current ?? "unknown")"
      + " · librime \(RimeEngine.librimeVersion)"
      + " · OS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\(location)\n"
      + "Recent records: \(lines.count) of \(records.count)\n"
    return header + (lines.isEmpty ? "\nNo records available." : "\n" + lines.reversed().joined(separator: "\n\n"))
  }
}
