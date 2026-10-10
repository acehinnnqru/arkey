import SwiftUI
import RimeEngine

/// Four explicit channel/size choices. Opening the screen alone does not make a network request.
struct CatalogView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel

  var body: some View {
    let _ = interfaceLocale
    List {
      Section {
        ForEach(RimeCatalog.standard.entries, id: \.id) { entry in
          VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayName).font(.headline)
            Text(entry.notes).font(.subheadline).foregroundStyle(.secondary)
            if let channel = entry.releaseChannel, let release = model.checkedReleases[channel] {
              Text(RimeLocalization.text("Release: \(release.tagName)"))
                .font(.caption).foregroundStyle(.secondary)
              if let asset = release.sourceArchive {
                Text(RimeProbe.formatted(bytes: UInt64(asset.size))).font(.caption)
              }
              if let url = URL(string: release.htmlURL) {
                Link(RimeLocalization.text("Release notes"), destination: url).font(.caption)
              }
            }
            HStack {
              Button(RimeLocalization.text("Download")) { model.startDownload(entry: entry) }
                .accessibilityIdentifier("download-" + entry.id)
                .disabled(model.isDownloading || model.isImporting || model.isDeploying)
              Spacer()
              if let address = entry.license.url, let url = URL(string: address) {
                Link(entry.license.spdx, destination: url).font(.caption)
              }
            }
          }
          .padding(.vertical, 6)
        }
      } header: {
        Text(RimeLocalization.text("Preset downloads"))
      } footer: {
        Text(RimeLocalization.text("Slim downloads the official full.zip, then removes the large dictionary locally. Download size is the same. Downloads install in Profile library; deployment is a separate action."))
      }
      if let message = model.downloadMessage {
        Section(RimeLocalization.text("Download status")) {
          Text(message.text).font(.footnote)
          if model.isDownloading {
            if let progress = model.downloadProgress { ProgressView(value: progress) }
            else { ProgressView() }
            Button(RimeLocalization.text("Cancel download")) { model.cancelDownload() }
              .disabled(model.isImporting)
          }
        }
      }
      Section {
        NavigationLink {
          ProfileLibraryView(model: model)
        } label: {
          Label(RimeLocalization.text("Profile library"), systemImage: "folder")
        }
        Link(RimeLocalization.text("Upstream repository"), destination: URL(string: "https://github.com/iDvel/rime-ice")!)
      } footer: {
        Text(RimeLocalization.text("Release uses the latest stable publication. Nightly follows development builds and is identified independently of GitHub’s prerelease flag."))
      }
    }
    .navigationTitle(RimeLocalization.text("Download profiles"))
    .accessibilityIdentifier("preset-downloads")
  }
}
