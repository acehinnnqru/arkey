import Combine
import Foundation
import RimeEngine
import SwiftUI

/// S2 §7: the user's patches and custom phrases as one file, so settings move between the phone and
/// Squirrel without copying a profile — and without the third-party sources, which are S1's business.
@MainActor
extension RimeAppModel {
  /// Writes the export into the app's Documents directory and returns it, so the share sheet has a
  /// real file to hand over. Nothing is uploaded anywhere.
  func exportSettings() -> URL? {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? workspace.root
    let url = documents.appendingPathComponent("arkey-settings-" + stamp + ".zip")
    do {
      let portability = RimeSettingsPortability(workspace: workspace, engine: engine)
      let bundle = try portability.export(to: url)
      if bundle.files.isEmpty {
        importWarnings = [RimeLocalization.message("No settings to export yet (no *.custom.yaml or custom phrases).")]
      } else {
        importWarnings = [RimeLocalization.message("Exported \(String(bundle.files.count)) settings files: \(bundle.fileNames.joined(separator: "、"))")]
      }
      return url
    } catch {
      errorMessage = RimeLocalization.message("Failed to export settings: \(String(describing: error))")
      return nil
    }
  }

  /// Imports a settings file the user picked: validated against its manifest, merged per file, with a
  /// backup taken first, and then deployed — because a patch that is not deployed is not in effect.
  func importSettingsBundle(from url: URL) async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let portability = RimeSettingsPortability(workspace: workspace, engine: engine)
      let incoming = try portability.inspect(url)
      let results = try portability.importSettings(from: url, merge: .replace)
      importWarnings = [RimeLocalization.message("Imported settings: \(String(results.count)) files (\(incoming.manifest.schemaIDs.joined(separator: "、")))")]
      await redeployActiveProfile()
    } catch {
      errorMessage = RimeLocalization.message("Failed to import settings: \(String(describing: error))")
    }
  }
}
