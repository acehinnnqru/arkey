import SwiftUI
import RimeEngine
import UniformTypeIdentifiers

/// The profile library screen: what is installed, what is deployed, and the one action that changes what the
/// keyboard types. Every write goes through the model, which owns the app's single engine.
struct ProfileLibraryView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel

  /// One picker per screen, not two. SwiftUI keeps a single presentation per view: with two fileImporters
  /// stacked on this List the toolbar's never presented at all — tapping 导入 did nothing, which is what
  /// round 189's UI test reproduced before this changed.
  ///
  /// The kind is a plain state the dismissal cannot touch. It used to live in the optional that the
  /// presentation binding clears, and that binding is cleared *before* the completion handler runs: the
  /// handler then read `nil`, skipped every branch and said nothing at all. Round 190's report was exactly
  /// that — the file was chosen in the picker and no import, no error and no message followed.
  private enum ImportKind {
    case profile
    case settings
  }
  @State private var isPicking = false
  @State private var pickKind: ImportKind = .profile
  private struct UserDataImportConfirmation {
    let candidates: [RimeUserDataCandidate]
    let continuation: CheckedContinuation<Bool?, Never>
  }
  @State private var pendingUserDataImport: UserDataImportConfirmation?
  @State private var showingUserDataImportConfirmation = false
  @State private var fileImportTask: Task<Void, Never>?
  @State private var isVisible = false
  @State private var showingURLImport = false
  @State private var pendingDeletion: RimeAppModel.LibraryEntry?
  @State private var pendingDictionaryDeletion: RimeAppModel.LibraryEntry?
  @State private var dictionariesToDelete: [String] = []
  @State private var busyProfileID: String?
  @State private var exported: URL?
  @State private var zipDownloadURL = ""

  var body: some View {
    let _ = interfaceLocale
    List {
      activeSection
      addProfilesSection
      installedSection
      downloadStatusSection
      deploymentSection
      settingsSection
      if !model.importWarnings.isEmpty { warningsSection }
      if let error = model.errorMessage { errorSection(error) }
      storageSection
    }
    .navigationTitle(RimeLocalization.text("Profile library"))
    .accessibilityIdentifier("profile-library")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          pickKind = .profile
          isPicking = true
        } label: {
          Label(RimeLocalization.text("Import"), systemImage: "square.and.arrow.down")
        }
        .disabled(model.isDeploying || model.isImporting || model.isDownloading)
      }
      ToolbarItem(placement: .topBarTrailing) {
        if model.isImporting {
          ProgressView().accessibilityLabel(RimeLocalization.text("Importing profile"))
        } else {
          Button(RimeLocalization.text("Refresh")) { model.refresh() }
        }
      }
    }
    // The union of both kinds' types; the handler refuses what the kind does not accept, which is what a
    // second importer was standing in for. The kind is read here, not from the presentation state.
    .fileImporter(isPresented: $isPicking,
                  allowedContentTypes: pickKind == .profile ? [.zip, .folder] : [.zip],
                  allowsMultipleSelection: false) { result in
      switch pickKind {
      case .profile:
        handleImport(result)
      case .settings:
        handleSettingsImport(result)
      }
    }
    .alert(RimeLocalization.text("Download ZIP from URL"), isPresented: $showingURLImport) {
      TextField(RimeLocalization.text("HTTPS ZIP download URL"), text: $zipDownloadURL)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("zip-download-url")
      Button(RimeLocalization.text("Download")) {
        model.startDownload(zipURL: zipDownloadURL, confirmUserData: confirmUserDataImport)
      }
      .disabled(zipDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button(RimeLocalization.text("Cancel"), role: .cancel) {}
    }
    .alert(RimeLocalization.text("Import user settings?"),
           isPresented: $showingUserDataImportConfirmation,
           presenting: pendingUserDataImport) { _ in
      Button(RimeLocalization.text("Import with user settings")) { resolveUserDataImport(true) }
      Button(RimeLocalization.text("Import profile only")) { resolveUserDataImport(false) }
      Button(RimeLocalization.text("Cancel"), role: .cancel) { resolveUserDataImport(nil) }
    } message: { confirmation in
      Text(RimeLocalization.text("This profile contains user settings: \(confirmation.candidates.map(\.relativePath).joined(separator: ", ")). Importing them replaces matching files in your user directory. Include them?"))
    }
    .onAppear { isVisible = true }
    .onDisappear {
      isVisible = false
      fileImportTask?.cancel()
      resolveUserDataImport(nil)
    }
    .confirmationDialog(RimeLocalization.text("Delete profile?"),
                        isPresented: Binding(get: { pendingDeletion != nil },
                                             set: { if !$0 { pendingDeletion = nil } }),
                        titleVisibility: .visible,
                        presenting: pendingDeletion) { entry in
      Button(RimeLocalization.text("Delete profile and keep user dictionaries"), role: .destructive) {
        model.delete(profileID: entry.metadata.id)
        pendingDeletion = nil
      }
      if !model.userDatabaseNames.isEmpty {
        Button(RimeLocalization.text("Delete profile and user dictionaries"), role: .destructive) {
          dictionariesToDelete = model.userDatabaseNames
          pendingDictionaryDeletion = entry
          pendingDeletion = nil
        }
      }
      Button(RimeLocalization.text("Cancel"), role: .cancel) { pendingDeletion = nil }
    } message: { entry in
      Text(deletionNote(for: entry))
    }
    .alert(RimeLocalization.text("Delete shared user dictionaries?"),
           isPresented: Binding(get: { pendingDictionaryDeletion != nil },
                                set: { if !$0 { pendingDictionaryDeletion = nil } }),
           presenting: pendingDictionaryDeletion) { entry in
      Button(RimeLocalization.text("Delete profile and user dictionaries"), role: .destructive) {
        model.delete(profileID: entry.id, removingUserDictionaries: dictionariesToDelete)
        pendingDictionaryDeletion = nil
        dictionariesToDelete = []
      }
      Button(RimeLocalization.text("Cancel"), role: .cancel) {
        pendingDictionaryDeletion = nil
        dictionariesToDelete = []
      }
    } message: { _ in
      Text(RimeLocalization.text("These shared dictionaries may be used by other profiles. Their learned words will be permanently deleted: \(dictionariesToDelete.joined(separator: ", ")). User settings, custom phrases, and sync backups will be kept."))
    }
  }

  // MARK: Sections

  private var activeSection: some View {
    Section(RimeLocalization.text("Active profile")) {
      VStack(alignment: .leading, spacing: 4) {
        Text(model.resolvedSummary.text).font(.body)
        if let deploy = model.libraryEntries.first(where: { $0.isActive })?.metadata.deploy {
          Text(deploy.deployedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(interfaceLocale))
               + " · " + String(deploy.warnings.count) + " warnings")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(RimeLocalization.text("Changes take effect when the keyboard next opens; current input is not interrupted."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var deploymentSection: some View {
    Section(RimeLocalization.text("Deployment")) {
      if let attempt = model.latestDeployment {
        HStack(spacing: 8) {
          if model.isDeploying { ProgressView() }
          VStack(alignment: .leading, spacing: 4) {
            Text(attempt.profileName).font(.subheadline)
            Text(UserFacing.text(attempt.message))
              .font(.caption)
              .foregroundStyle(attempt.failed ? Color.red : Color.secondary)
              .lineLimit(2)
          }
        }
      }
      NavigationLink {
        DeploymentLogView(model: model)
      } label: {
        Label(RimeLocalization.text("Deployment log"), systemImage: "doc.text.magnifyingglass")
      }
      .accessibilityIdentifier("deployment-log-link")
    }
  }

  private var addProfilesSection: some View {
    Section {
      NavigationLink {
        CatalogView(model: model)
      } label: {
        Label(RimeLocalization.text("Download profiles"), systemImage: "arrow.down.circle")
      }
      .accessibilityIdentifier("profile-downloads-link")
      Button {
        pickKind = .profile
        isPicking = true
      } label: {
        Label(RimeLocalization.text("Import ZIP from Files"), systemImage: "doc.zipper")
      }
      .disabled(model.isDeploying || model.isImporting || model.isDownloading)
      Button {
        showingURLImport = true
      } label: {
        Label(RimeLocalization.text("Download ZIP from URL"), systemImage: "link")
      }
      .accessibilityIdentifier("profile-url-import-button")
      .disabled(model.isDeploying || model.isImporting || model.isDownloading)
    } header: {
      Text(RimeLocalization.text("Add profiles"))
    } footer: {
      Text(RimeLocalization.text("Choose a ZIP, share a ZIP to Arkey from another app, or enter an HTTPS ZIP link. Import installs a profile without deploying it."))
    }
  }

  @ViewBuilder
  private var downloadStatusSection: some View {
    if model.downloadEntryID == nil, let message = model.downloadMessage {
      Section(RimeLocalization.text("Download status")) {
        Text(message.text).font(.footnote)
        if model.isDownloading {
          if let progress = model.downloadProgress { ProgressView(value: progress) }
          else { ProgressView() }
          Button(RimeLocalization.text("Cancel download")) { model.cancelDownload() }
            .disabled(model.isImporting)
        } else {
          Button(RimeLocalization.text("Clear")) { model.clearDownloadStatus() }
        }
      }
    }
  }

  private var installedSection: some View {
    Section(RimeLocalization.text("Installed (\(String(model.libraryEntries.count)))")) {
      if model.libraryEntries.isEmpty {
        Text(RimeLocalization.text("No profiles yet. Import a zip or folder, such as rime-ice’s full.zip or a copy of ~/Library/Rime from a Mac."))
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
        Text(model.catalogEntry(for: entry.metadata)?.displayName ?? entry.metadata.displayName).font(.body.weight(.medium))
        if entry.isActive {
          Text(RimeLocalization.text("Active")).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
        }
        if busyProfileID == entry.metadata.id { ProgressView().controlSize(.mini) }
      }
      Text(entry.metadata.id).font(.caption2).foregroundStyle(.secondary)
      Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
      if let tag = entry.metadata.source.releaseTag {
        Text(RimeLocalization.text("Release: \(tag)")).font(.caption).foregroundStyle(.secondary)
      }
      if let preset = model.catalogEntry(for: entry.metadata) {
        HStack {
          Spacer()
          ProfileDownloadButton(model: model, entry: preset)
        }
        Text(RimeLocalization.text("Updates install separately and keep this version. Deployment success alone does not guarantee that every existing custom patch is compatible."))
          .font(.caption2).foregroundStyle(.secondary)
      }
      HStack(spacing: 12) {
        Button(entry.isActive ? RimeLocalization.text("Redeploy") : RimeLocalization.text("Deploy")) { deploy(entry) }
        Button(RimeLocalization.text("Activate")) { model.activate(profileID: entry.metadata.id) }
          .disabled(entry.isActive)
        if entry.metadata.deploy != nil {
          Button(RimeLocalization.text("Roll back")) { model.rollback(profileID: entry.metadata.id) }
        }
        Button(RimeLocalization.text("Delete"), role: .destructive) {
          pendingDeletion = entry
        }
      }
      .font(.caption)
      .buttonStyle(.borderless)
      .disabled(model.isDeploying || model.isImporting || model.isDownloading)
    }
    .padding(.vertical, 2)
  }

  /// S2 §7: plain text the user can read, moved between devices without the third-party sources.
  private var settingsSection: some View {
    Section {
      if let exported {
        ShareLink(item: exported) { Text(RimeLocalization.text("Share exported settings")) }
      } else {
        Button(RimeLocalization.text("Export settings (patches and custom phrases)")) { exported = model.exportSettings() }
      }
      Button(RimeLocalization.text("Import settings…")) {
        pickKind = .settings
        isPicking = true
      }
      .disabled(model.isImporting)
      Button {
        Task { await model.restoreLatestSettingsBackup() }
      } label: {
        Text(RimeLocalization.text("Restore latest settings backup and redeploy"))
      }
      .disabled(model.isDeploying || model.isImporting || model.isDownloading || model.profiles.isEmpty
                || model.latestSettingsBackup == nil)
    } header: {
      Text(RimeLocalization.text("Settings"))
    } footer: {
      Text(RimeLocalization.text("Exports contain *.custom.yaml and custom phrases, excluding third-party profile data. Import backs up current settings and redeploys automatically."))
    }
  }

  private var warningsSection: some View {
    Section(RimeLocalization.text("Import results")) {
      ForEach(Array(model.importWarnings.enumerated()), id: \.offset) { _, warning in
        Text(warning.text).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func errorSection(_ message: RimeLocalizedMessage) -> some View {
    Section(RimeLocalization.text("Error")) {
      Text(UserFacing.text(message)).font(.caption).foregroundStyle(.red)
      Button(RimeLocalization.text("Clear")) { model.errorMessage = nil }.font(.caption)
    }
  }

  private var storageSection: some View {
    Section(RimeLocalization.text("Storage")) {
      if let storage = model.storage {
        ForEach(storage.profiles, id: \.id) { profile in
          Text(profile.displayName + "：" + bytes(profile.sourceBytes + profile.buildBytes + profile.previousBuildBytes))
            .font(.caption)
        }
        Text(RimeLocalization.text("User directory: \(bytes(storage.userDataBytes))")).font(.caption)
        Text(RimeLocalization.text("Total: \(bytes(storage.totalBytes))")).font(.caption).foregroundStyle(.secondary)
      } else {
        Text(RimeLocalization.text("(not measured yet)")).font(.caption).foregroundStyle(.secondary)
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
      model.errorMessage = RimeLocalization.message("Failed to select a file: \(String(describing: error))")
    case .success(let urls):
      guard let url = urls.first else { return }
      fileImportTask = Task {
        await model.importPayload(at: url, displayName: nil, adoptUserData: false,
                                  confirmUserData: confirmUserDataImport)
      }
    }
  }

  private func confirmUserDataImport(_ candidates: [RimeUserDataCandidate]) async -> Bool? {
    guard isVisible, !Task.isCancelled else { return nil }
    return await withCheckedContinuation { continuation in
      pendingUserDataImport = UserDataImportConfirmation(candidates: candidates, continuation: continuation)
      showingUserDataImportConfirmation = true
    }
  }

  private func resolveUserDataImport(_ decision: Bool?) {
    guard let pending = pendingUserDataImport else { return }
    pendingUserDataImport = nil
    pending.continuation.resume(returning: decision)
  }

  /// The settings import takes a zip and nothing else, which the shared picker has to say for itself.
  private func handleSettingsImport(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      model.errorMessage = RimeLocalization.message("Failed to select a file: \(String(describing: error))")
    case .success(let urls):
      guard let url = urls.first else { return }
      guard url.pathExtension.lowercased() == "zip" else {
        model.errorMessage = RimeLocalization.message("Import requires a zip created by Export settings. Selected: \(url.lastPathComponent).")
        return
      }
      Task { await model.importSettingsBundle(from: url) }
    }
  }

  private func deletionNote(for entry: RimeAppModel.LibraryEntry) -> String {
    let name = model.catalogEntry(for: entry.metadata)?.displayName ?? entry.metadata.displayName
    let message = RimeLocalization.message("Deleting \(name) removes its source files, compiled files, and previous build. User dictionaries, settings, custom phrases, and sync backups are kept by default.")
    if entry.isActive {
      return RimeLocalization.text("\(message) This is the active profile. The keyboard will use built-in data the next time it opens.")
    }
    return message.text
  }

  private func detail(_ entry: RimeAppModel.LibraryEntry) -> String {
    var parts: [String] = []
    parts.append(RimeLocalization.text("Schemes \(String(entry.metadata.stats.schemaIDs.count))"))
    parts.append(RimeLocalization.text("Sources \(bytes(entry.metadata.stats.sourceBytes))"))
    parts.append(RimeLocalization.text("Build \(bytes(entry.buildBytes))"))
    if let license = entry.metadata.license?.spdx { parts.append(license) }
    if let deploy = entry.metadata.deploy {
      parts.append(RimeLocalization.text("Generation \(String(deploy.generation))"))
      parts.append(String(format: "%.1f s", locale: interfaceLocale, deploy.durationSeconds))
    } else {
      parts.append(RimeLocalization.text("Not deployed"))
    }
    return parts.joined(separator: " · ")
  }

  /// The engine's one size format: this screen used to carry its own `ByteCountFormatter`, and the
  /// diagnostics screen a third style for the same number.
  private func bytes(_ value: Int) -> String {
    RimeProbe.formatted(bytes: UInt64(max(0, value)))
  }
}
