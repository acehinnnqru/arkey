import SwiftUI
import RimeEngine
import UniformTypeIdentifiers

/// The 配置库 screen: what is installed, what is deployed, and the one action that changes what the
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
  @State private var adoptUserData = false
  @State private var pendingDeletion: RimeAppModel.LibraryEntry?
  @State private var deleteDictionaries = false
  @State private var busyProfileID: String?
  @State private var exported: URL?

  var body: some View {
    let _ = interfaceLocale
    List {
      activeSection
      deploymentSection
      installedSection
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
        .disabled(model.isDeploying || model.isImporting)
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
                  allowedContentTypes: [.zip, .folder],
                  allowsMultipleSelection: false) { result in
      switch pickKind {
      case .profile:
        handleImport(result)
      case .settings:
        handleSettingsImport(result)
      }
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
      Button(RimeLocalization.text("Delete profile and user dictionaries"), role: .destructive) {
        model.delete(profileID: entry.metadata.id, removingUserDictionaries: model.userDatabaseNames)
        pendingDeletion = nil
      }
      Button(RimeLocalization.text("Cancel"), role: .cancel) { pendingDeletion = nil }
    } message: { entry in
      Text(dictionaryNote(for: entry))
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
      Toggle(RimeLocalization.text("Include user settings when importing (*.custom.yaml, custom_phrase.txt)"), isOn: $adoptUserData)
        .font(.footnote)
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
        Text(entry.metadata.displayName).font(.body.weight(.medium))
        if entry.isActive {
          Text(RimeLocalization.text("Active")).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
        }
        if busyProfileID == entry.metadata.id { ProgressView().controlSize(.mini) }
      }
      Text(entry.metadata.id).font(.caption2).foregroundStyle(.secondary)
      Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button(entry.isActive ? RimeLocalization.text("Redeploy") : RimeLocalization.text("Deploy")) { deploy(entry) }
        Button(RimeLocalization.text("Activate")) { model.activate(profileID: entry.metadata.id) }
          .disabled(entry.isActive)
        if entry.metadata.deploy != nil {
          Button(RimeLocalization.text("Roll back")) { model.rollback(profileID: entry.metadata.id) }
        }
        Button(RimeLocalization.text("Delete"), role: .destructive) {
          deleteDictionaries = false
          pendingDeletion = entry
        }
      }
      .font(.caption)
      .buttonStyle(.borderless)
      .disabled(model.isDeploying || model.isImporting)
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
      .disabled(model.isDeploying || model.isImporting || model.profiles.isEmpty
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
      Task { await model.importPayload(at: url, displayName: nil, adoptUserData: adoptUserData) }
    }
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

  private func dictionaryNote(for entry: RimeAppModel.LibraryEntry) -> String {
    let names = model.userDatabaseNames
    let base = RimeLocalization.text("User dictionaries belong to dictionary names. Deleting a profile keeps them by default, preserving learned words when you switch back.")
    return names.isEmpty ? base : RimeLocalization.text("\(base) Currently contains: \(names.joined(separator: "、"))")
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
