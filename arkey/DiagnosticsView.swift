import Foundation
import SwiftUI
import RimeEngine
import UIKit

/// Reads the probe log the keyboard writes, so a failure on a device can be copied out of the
/// app instead of guessed at from a truncated line above the keys.
struct DiagnosticsView: View {
  @Environment(\.locale) private var interfaceLocale
  @StateObject private var model = RimeAppModel.shared
  @State private var records: [RimeProbeRecord] = []
  @State private var status = RimeLocalization.message("Loading…")
  @State private var showingClearConfirmation = false
  @State private var showingCopyResult = false
  @State private var copyResult: RimeLocalizedMessage = ""
  @State private var logReadID = UUID()

  var body: some View {
    let _ = interfaceLocale
    List {
      Section(RimeLocalization.text("Profile")) {
        // S1 §9: every degraded mode names the exact path this process resolves.
        Text(model.resolvedSummary.text).font(.footnote)
        if let resolved = model.resolved {
          Text("shared  " + resolved.directories.sharedDataDir)
            .font(.caption2).foregroundStyle(.secondary)
          Text("prebuilt  " + resolved.directories.prebuiltDataDir)
            .font(.caption2).foregroundStyle(.secondary)
          Text("user  " + resolved.directories.userDataDir)
            .font(.caption2).foregroundStyle(.secondary)
        }
        Text(model.engineStatus.text).font(.caption).foregroundStyle(.secondary)
        // S6 §4: a bug report has to name both versions, so the screen shows both — the app's from its
        // own bundle, the engine's from the library that is linked into it.
        Text("librime " + RimeEngine.librimeVersion
             + (RimeHostVersion.current.map { " · app " + $0 } ?? RimeLocalization.text(" · app unknown")))
          .font(.caption).foregroundStyle(.secondary)
        Text(RimeLocalization.text("Installed profiles: \(String(model.profiles.count))"))
          .font(.caption).foregroundStyle(.secondary)
      }

      Section(RimeLocalization.text("Container")) {
        Text(status.text)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section(RimeLocalization.text("Export")) {
        ShareLink(RimeLocalization.text("Share diagnostics"), item: DiagnosticsReport.text(records: records, location: status.text))
        Text(RimeLocalization.text("Recent records are shown below. Repeated legacy layout events are grouped."))
          .font(.caption).foregroundStyle(.secondary)
      }

      if records.isEmpty {
        Section {
          Text(RimeLocalization.text("No logs yet. Enable the Arkey keyboard and Full Access in Settings, type a few keys, then return and refresh."))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      } else {
        // S1-AC8 and S4-AC6: the numbers first, because that is what the acceptance criteria read, and
        // the raw lines under them for the case the numbers do not explain.
        Section(RimeLocalization.text("Statistics")) {
          ForEach(RimeProbeSummary(records: records).orderedPhases, id: \.name) { phase in
            VStack(alignment: .leading, spacing: 2) {
              Text(phase.name).font(.footnote.bold())
              Text(summaryLine(phase)).font(.caption).foregroundStyle(.secondary)
            }
          }
        }

        Section(RimeLocalization.text("Keyboard log (\(String(records.count)) records)")) {
          ForEach(Array(records.enumerated()), id: \.offset) { _, record in
            VStack(alignment: .leading, spacing: 3) {
              Text(record.phase).font(.footnote.bold())
              Text(detail(record)).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .navigationTitle(RimeLocalization.text("Diagnostics"))
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(RimeLocalization.text("Refresh")) { Task { await loadInBackground() } }
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button(RimeLocalization.text("Clear")) { showingClearConfirmation = true }
          .disabled(logURL == nil)
        Button(RimeLocalization.text("Copy")) { copyAll() }
          .accessibilityIdentifier("diagnostics-copy")
      }
    }
    .confirmationDialog(RimeLocalization.text("Clear keyboard logs?"),
                        isPresented: $showingClearConfirmation,
                        titleVisibility: .visible) {
      Button(RimeLocalization.text("Clear \(String(records.count)) records"), role: .destructive) { clear() }
      Button(RimeLocalization.text("Cancel"), role: .cancel) {}
    } message: {
      Text(RimeLocalization.text("This clears the entire log folder, including probe and librime logs. Keyboard settings, dictionaries, and user data are unaffected. Clearing cannot be undone."))
    }
    .alert(RimeLocalization.text("Diagnostics"), isPresented: $showingCopyResult) {
      Button(RimeLocalization.text("OK"), role: .cancel) {}
    } message: {
      Text(copyResult.text)
    }
    .task { await loadInBackground() }
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
    logReadID = UUID()
    guard let url = logURL else {
      status = RimeLocalization.message("App Group container is unavailable. Enable Allow Full Access in keyboard settings, then reopen the keyboard.")
      records = []
      return
    }
    records = DiagnosticsReport.compact(RimeProbeLog(url: url).readAll())
    ProbeLogLocation.mirrorIntoAppContainer()
    status = records.isEmpty
      ? RimeLocalization.message("\(url.path) (no records)")
      : RimeLocalizedMessage(verbatim: url.path)
  }

  private func loadInBackground() async {
    guard let url = logURL else {
      load()
      return
    }
    let readID = UUID()
    logReadID = readID
    let loaded = await Task.detached(priority: .userInitiated) {
      let records = DiagnosticsReport.compact(RimeProbeLog(url: url).readAll())
      ProbeLogLocation.mirrorIntoAppContainer()
      return records
    }.value
    guard !Task.isCancelled, logReadID == readID else { return }
    records = loaded
    status = loaded.isEmpty ? RimeLocalization.message("\(url.path) (no records)") : RimeLocalizedMessage(verbatim: url.path)
  }

  private func copyAll() {
    load()
    let report = DiagnosticsReport.text(records: records, location: status.text)
    UIPasteboard.general.string = report
    copyResult = UIPasteboard.general.string == report
      ? RimeLocalization.message("Copied the latest diagnostics. You can paste them into a message.")
      : RimeLocalization.message("Copy failed. Use Share diagnostics to export the report.")
    showingCopyResult = true
  }

  /// One phase as a line: how many samples, and the numbers a reader compares against the spec.
  private func summaryLine(_ phase: RimeProbeSummary.Phase) -> String {
    var parts = [RimeLocalization.text("\(String(phase.count)) samples")]
    if let median = phase.medianMilliseconds {
      parts.append(RimeLocalization.text("Median \(String(format: "%.1f", locale: interfaceLocale, median)) ms"))
    }
    if let p95 = phase.p95Milliseconds {
      parts.append("p95 " + String(format: "%.1f", locale: interfaceLocale, p95) + " ms")
    }
    if let worst = phase.maxMilliseconds {
      parts.append(RimeLocalization.text("Worst \(String(format: "%.1f", locale: interfaceLocale, worst)) ms"))
    }
    if let bytes = phase.lastFootprintBytes {
      parts.append(RimeLocalization.text("Memory \(RimeProbe.formatted(bytes: bytes))"))
    }
    if let bytes = phase.maxFootprintBytes, bytes != phase.lastFootprintBytes {
      parts.append(RimeLocalization.text("Peak \(RimeProbe.formatted(bytes: bytes))"))
    }
    if let message = phase.lastMessage, !phase.name.hasPrefix("keyboard.geometry.") {
      parts.append(message)
    }
    return parts.joined(separator: " · ")
  }

  private func detail(_ record: RimeProbeRecord) -> String {
    var parts = [Self.time.string(from: record.timestamp)]
    if let milliseconds = record.milliseconds {
      parts.append(String(format: "%.1f ms", locale: interfaceLocale, milliseconds))
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
