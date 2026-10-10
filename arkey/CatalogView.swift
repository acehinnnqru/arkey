import SwiftUI
import RimeEngine

/// S1 §2's catalog entries: the configs the project's own page offers, with the licence and the cost of
/// each laid out before the user commits to it.
///
/// The app fetches nothing itself. Every row opens the project's page in the system browser, and what
/// the user downloads comes back through the ordinary import pipeline — the hardened zip path — which
/// is what S6 §5 asks for ("the app links to it and never re-hosts an archive"). S1 §5 calls the in-app
/// fetch "later and optionally"; not having it removes the only network path from the app, which is
/// also the strongest answer to the review question in S6 §6.
struct CatalogView: View {
  @Environment(\.locale) private var interfaceLocale
  var body: some View {
    let _ = interfaceLocale
    List {
      Section {
        ForEach(RimeCatalog.standard.entries, id: \.id) { entry in
          row(entry)
        }
      } header: {
        Text(RimeLocalization.text("Available profiles"))
      } footer: {
        Text(RimeLocalization.text("Downloads open in the system browser. Return to Profile library → Import to install the zip. This app does not make network requests or host third-party data."))
      }
      Section(RimeLocalization.text("Import")) {
        Text(RimeLocalization.text("Import uses the same hardened archive extraction, profile root detection, and per-file validation. Failures name the file and reason."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .navigationTitle(RimeLocalization.text("Download profiles"))
  }

  private func row(_ entry: RimeCatalogEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.displayName).font(.body.weight(.medium))
      Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
      Text(entry.notes).font(.caption2).foregroundStyle(.secondary)
      HStack(spacing: 14) {
        if entry.isSecure, let url = URL(string: entry.pageURL) {
          Link(RimeLocalization.text("Open project page"), destination: url).font(.caption)
        } else {
          Text(RimeLocalization.text("Project page hidden because its address does not use HTTPS")).font(.caption).foregroundStyle(.orange)
        }
        if let source = entry.license.sourceURL, let url = URL(string: source) {
          Link(RimeLocalization.text("Upstream repository"), destination: url).font(.caption)
        }
        if let licensePage = entry.license.url, let url = URL(string: licensePage) {
          Link(entry.license.spdx, destination: url).font(.caption)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func detail(_ entry: RimeCatalogEntry) -> String {
    var parts = [entry.license.spdx,
                 RimeProbe.formatted(bytes: UInt64(max(0, entry.approximateBytes))),
                 RimeLocalization.text("\(String(entry.requirements.schemaCount)) schemes")]
    if entry.requirements.needsLua { parts.append(RimeLocalization.text("Includes Lua")) }
    if entry.requirements.needsGrammarModel { parts.append(RimeLocalization.text("Includes grammar model")) }
    if entry.requirements.needsPredict { parts.append(RimeLocalization.text("Includes prediction")) }
    return parts.joined(separator: " · ")
  }
}
