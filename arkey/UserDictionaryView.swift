import SwiftUI
import UniformTypeIdentifiers
import RimeEngine

/// S5's 用户词库 screen. Every action states whether it can run: the keyboard holds the dictionaries
/// while it is on screen, and librime does not report the second opener — it hands back a dictionary
/// that is silently not loaded, which is why this refuses instead.
struct UserDictionaryView: View {
  @Environment(\.locale) private var interfaceLocale
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
  @State private var importMessage: RimeLocalizedMessage = ""
  @State private var pendingRemoval: String?
  @State private var query = ""

  var body: some View {
    let _ = interfaceLocale
    List {
      if let report = model.dictionaryReport {
        // S5-AC6: learning off is an explanation, not an error.
        if let reason = model.syncDisabledReason {
          Section {
            Text(reason.text).font(.caption).foregroundStyle(.orange)
          }
        }
        let matching = model.filteredDictionaries(matching: query)
        if report.dictionaries.isEmpty {
          Section {
            Text(RimeLocalization.text("No user dictionaries yet. Enable the keyboard and Full Access, then type a few words."))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        } else if matching.isEmpty {
          Section { Text(RimeLocalization.text("No dictionaries match “\(query)”.")).font(.footnote).foregroundStyle(.secondary) }
        } else {
          Section(RimeLocalization.text("Dictionaries (\(String(matching.count)))")) {
            ForEach(matching, id: \.name) { entry in
              row(entry)
            }
          }
        }
        backupsSection(report)
        syncSection(report)
      } else {
        Section { Text(RimeLocalization.text("Loading…")).font(.footnote) }
      }
      if let message = model.syncMessage { Section(RimeLocalization.text("Sync")) { Text(message.text).font(.caption) } }
      if let error = model.errorMessage { UserFacing.errorRow(error) }
    }
    .navigationTitle(RimeLocalization.text("User dictionaries"))
    .searchable(text: $query, prompt: RimeLocalization.text("Search dictionary names"))
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(RimeLocalization.text("Refresh")) { Task { await model.refreshDictionariesInBackground() } }
      }
    }
    .confirmationDialog(RimeLocalization.text("Clear this dictionary?"),
                        isPresented: Binding(get: { pendingRemoval != nil },
                                             set: { if !$0 { pendingRemoval = nil } }),
                        titleVisibility: .visible) {
      Button(RimeLocalization.text("Clear and delete"), role: .destructive) {
        if let name = pendingRemoval { model.removeDictionary(name) }
        pendingRemoval = nil
      }
      Button(RimeLocalization.text("Cancel"), role: .cancel) { pendingRemoval = nil }
    } message: {
      Text(RimeLocalization.text("This deletes the entire dictionary and cannot be undone. To forget one word, hold its candidate in the keyboard (Shift+Delete on desktop).librime imports add entries; removing a line and importing again does not delete that word."))
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
        model.errorMessage = RimeLocalization.message("Failed to select a file: \(String(describing: error))")
      case (.syncFolder, .success(let url)):
        model.chooseSyncFolder(url)
      case (.syncFolder, .failure(let error)):
        model.errorMessage = RimeLocalization.message("Failed to select a folder: \(String(describing: error))")
      }
    }
  }

  private func row(_ entry: RimeUserDictionaryReport.Entry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.name).font(.body.weight(.medium))
      Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
      if entry.isDamaged {
        VStack(alignment: .leading, spacing: 2) {
          Text(RimeLocalization.text("librime could not open dictionary “\(entry.name)” and rebuilt it as an empty dictionary; writes will also fail.Restore a backup below or merge snapshots from another device."))
            .font(.caption2).foregroundStyle(.orange)
          ForEach(entry.databaseIssues, id: \.message) { issue in
            Text((issue.isReadOnly ? RimeLocalization.text("Read only: ") : RimeLocalization.text("Corrupted: ")) + issue.message)
              .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
          }
        }
      }
      otherDeviceRows(entry)
      if entry.conflictCopies > 0 {
        Text(RimeLocalization.text("There are \(String(entry.conflictCopies)) iCloud conflict copies; all will be read"))
          .font(.caption2).foregroundStyle(.orange)
      }
      HStack(spacing: 12) {
        Button(RimeLocalization.text("Export (levers format; not readable by Squirrel)")) {
          exported = model.exportDictionary(entry.name)
        }
        Button(RimeLocalization.text("Export snapshot (readable by Squirrel)")) {
          exportedSnapshot = model.exportSnapshot(entry.name)
        }
        Button(RimeLocalization.text("Import…")) {
          pendingImport = entry.name
          pick = .dictionary
          isPicking = true
        }
        Button(RimeLocalization.text("Back up")) { model.backupDictionary(entry.name) }
        if let snapshot = exportedSnapshot {
          ShareLink(item: snapshot) { Text(RimeLocalization.text("Share snapshot")) }.font(.caption)
        }
        Button(RimeLocalization.text("Clear dictionary"), role: .destructive) {
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
      Section(RimeLocalization.text("Backups (three most recent per dictionary)")) {
        ForEach(files, id: \.url) { file in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(file.name).font(.caption)
              Text(file.url.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(RimeLocalization.text("Restore")) { model.restoreDictionary(file.name, from: file.url) }
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
          Text(RimeLocalization.text("Other device \(device.deviceID)")).font(.caption2)
          Text(Self.stamp.string(from: device.modifiedAt) + " · " + bytes(device.bytes)
               + (device.isConflictCopy ? RimeLocalization.text(" · iCloud conflict copy") : ""))
            .font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button(RimeLocalization.text("Merge")) { Task { await model.mergeDictionaries(from: device.deviceID) } }
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
    Section(RimeLocalization.text("Sync")) {
      Button {
        Task { await model.syncDictionaries() }
      } label: {
        HStack {
          Text(RimeLocalization.text("Sync now"))
          if model.isSyncing { Spacer(); ProgressView() }
        }
      }
      .disabled(model.isSyncing || !report.isLeaseCold || model.syncDisabledReason != nil)
      Button {
        Task { await model.mergeDictionaries() }
      } label: {
        HStack {
          Text(RimeLocalization.text("Merge other devices"))
          if model.isSyncing { Spacer(); ProgressView() }
        }
      }
      .disabled(model.isSyncing || !report.isLeaseCold || model.syncDisabledReason != nil)
      Text(RimeLocalization.text("Read other devices’ snapshots in the shared folder and add them to this dictionary. A backup is made before merging."))
        .font(.caption2).foregroundStyle(.secondary)
      if let leaseReason = report.leaseBlocker {
        // The engine's own sentence: a live keyboard and an unreadable lease file are different
        // situations, and the screen should not describe one as the other.
        Text(leaseReason.description)
          .font(.caption).foregroundStyle(.orange)
      }
      if let set = exportedSet {
        ShareLink(item: set) { Text(RimeLocalization.text("Share all snapshots (zip)")) }.font(.caption)
      } else {
        Button(RimeLocalization.text("Export all snapshots (zip)")) { exportedSet = model.exportAllDictionaries() }
          .font(.caption)
          .disabled(model.isSyncing)
      }
      if let directory = report.syncDirectory {
        Text(UserFacing.text(directory)).font(.caption2).foregroundStyle(.secondary)
      } else {
        Text(RimeLocalization.text("Sync folder has not been initialized")).font(.caption2).foregroundStyle(.secondary)
      }
      // S5 §6's alternative: a folder the user picked, held as a bookmark, validated when it changes.
      if let choice = model.syncChoice {
        Text(RimeLocalization.text("Custom folder (selected \(Self.stamp.string(from: choice.chosenAt)))"))
          .font(.caption2).foregroundStyle(.secondary)
        Button(RimeLocalization.text("Restore default (iCloud / Documents)")) { model.useDefaultSyncFolder() }
          .font(.caption)
          .disabled(model.isSyncing)
      } else {
        Button(RimeLocalization.text("Choose sync folder…")) {
          pick = .syncFolder
          isPicking = true
        }
          .font(.caption)
          .disabled(model.isSyncing)
      }
      if let problem = model.syncChoiceProblem {
        Text(problem.text).font(.caption2).foregroundStyle(.orange)
      }
      if let id = report.installationID {
        Text("installation_id " + id).font(.caption2).foregroundStyle(.secondary)
      }
      Text(RimeLocalization.text("Learning belongs to dictionary names, so switching profiles and back preserves learned words."))
        .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func detail(_ entry: RimeUserDictionaryReport.Entry) -> String {
    var parts = [bytes(entry.databaseBytes)]
    parts.append(RimeLocalization.text("\(String(entry.entryCount)) entries"))
    if entry.localSnapshotBytes > 0 { parts.append(RimeLocalization.text("Local snapshot \(bytes(entry.localSnapshotBytes))")) }
    if !entry.isLearned { parts.append(RimeLocalization.text("No learned words yet")) }
    return parts.joined(separator: " · ")
  }

  /// The engine's one size format: this screen used to carry its own `ByteCountFormatter`, and the
  /// diagnostics screen a third style for the same number.
  private func bytes(_ value: Int) -> String {
    RimeProbe.formatted(bytes: UInt64(max(0, value)))
  }
}
