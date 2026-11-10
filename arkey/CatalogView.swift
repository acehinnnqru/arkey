import SwiftUI
import RimeEngine

/// Four explicit channel/size choices. Opening the screen alone does not make a network request.
struct CatalogView: View {
  @Environment(\.locale) private var interfaceLocale
  @Environment(\.dismiss) private var dismiss
  @State private var showingDownloadError = false
  @ObservedObject var model: RimeAppModel

  var body: some View {
    let _ = interfaceLocale
    List {
      Section {
        ForEach(RimeCatalog.standard.entries, id: \.id) { entry in
          VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayName).font(.headline)
            Text(entry.notes).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 16) {
              if let address = entry.license.url, let url = URL(string: address) {
                Link(entry.license.spdx, destination: url)
                  .font(.caption)
                  .buttonStyle(.borderless)
                  .padding(.vertical, 12)
                  .accessibilityIdentifier("license-" + entry.id)
              }
              Spacer(minLength: 16)
              ProfileDownloadButton(model: model, entry: entry, onInstalled: { dismiss() })
            }
          }
          .padding(.vertical, 6)
        }
      } header: {
        Text(RimeLocalization.text("Preset downloads"))
      } footer: {
        Text(RimeLocalization.text("Downloaded profiles must be deployed from Profile library before use."))
      }
      Section {
        Link(RimeLocalization.text("Upstream repository"), destination: URL(string: "https://github.com/iDvel/rime-ice")!)
      }
    }
    .navigationTitle(RimeLocalization.text("Download profiles"))
    .settingsHelp {
      Section(RimeLocalization.text("Preset downloads")) {
        Text(RimeLocalization.text("Slim omits the large dictionary but downloads the same amount of data as Full."))
        Text(RimeLocalization.text("Release follows stable versions; Nightly follows development builds."))
      }
    }
    .accessibilityIdentifier("preset-downloads")
    .onChange(of: model.downloadPhase) { _, phase in
      showingDownloadError = phase == .failed && model.downloadEntryID != nil
    }
    .alert(RimeLocalization.text("Download failed"), isPresented: $showingDownloadError) {
      Button(RimeLocalization.text("Retry")) {
        if let id = model.downloadEntryID, let entry = RimeCatalog.standard.entry(id: id) {
          model.startDownload(entry: entry)
        }
      }
      Button(RimeLocalization.text("Cancel"), role: .cancel) {}
    } message: {
      Text(model.downloadMessage?.text ?? "")
    }
  }

}

/// The catalog and installed library rows share one control for acquisition state.
struct ProfileDownloadButton: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel
  let entry: RimeCatalogEntry
  var onInstalled: (() -> Void)? = nil

  var body: some View {
    let action = model.catalogDownloadAction(for: entry)
    let isBusy = action == .downloading || action == .installing
    return Button {
      switch action {
      case .downloading: model.cancelDownload()
      case .installing: break
      case .installed: onInstalled?()
      case .download, .update, .retry: model.startDownload(entry: entry)
      }
    } label: {
      Group {
        if action == .downloading {
          ProfileDownloadProgress(progress: model.downloadProgress)
        } else if action == .installing {
          ProgressView()
        } else {
          Text(buttonLabel(action)).font(.subheadline.weight(.semibold))
        }
      }
      .frame(minWidth: 72, minHeight: 44)
      .background(isBusy ? Color.clear : Color.accentColor.opacity(0.12), in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.borderless)
    .accessibilityIdentifier("download-" + entry.id)
    .accessibilityLabel(buttonLabel(action))
    .accessibilityValue(isBusy ? (model.downloadProgress?.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale))
      ?? model.downloadMessage?.text ?? "") : "")
    .accessibilityHint(action == .installed && onInstalled != nil ? RimeLocalization.text("View installed profiles") : "")
    .disabled(action == .installing || (action == .installed && onInstalled == nil) || (!isBusy && (model.isDownloading || model.isImporting || model.isDeploying)))
  }

  private func buttonLabel(_ action: RimeAppModel.CatalogDownloadAction) -> String {
    switch action {
    case .download: return RimeLocalization.text("Download")
    case .update: return RimeLocalization.text("Update")
    case .installed: return RimeLocalization.text("Installed")
    case .retry: return RimeLocalization.text("Retry")
    case .downloading: return RimeLocalization.text("Cancel download")
    case .installing: return RimeLocalization.text("Installing profile")
    }
  }
}

private struct ProfileDownloadProgress: View {
  let progress: Double?
  @State private var rotating = false

  var body: some View {
    ZStack {
      Circle().stroke(.tint.opacity(0.2), lineWidth: 3)
      Circle().trim(from: 0, to: progress.map { min(1, max(0, $0)) } ?? 0.25)
        .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(progress == nil && rotating ? 270 : -90))
        .animation(progress == nil ? .linear(duration: 1).repeatForever(autoreverses: false) : nil,
                   value: rotating)
        .animation(.linear(duration: 0.15), value: progress)
      RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 8, height: 8)
    }
    .frame(width: 28, height: 28)
    .onAppear { rotating = progress == nil }
    .onChange(of: progress == nil) { _, indeterminate in rotating = indeterminate }
  }
}
