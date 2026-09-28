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
        importWarnings = ["当前没有可导出的设置（还没有任何 *.custom.yaml 或自定义短语）。"]
      } else {
        importWarnings = ["已导出 " + String(bundle.files.count) + " 个设置文件："
                          + bundle.fileNames.joined(separator: "、")]
      }
      return url
    } catch {
      errorMessage = "导出设置失败：" + String(describing: error)
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
      importWarnings = ["导入设置：" + String(results.count) + " 个文件（"
                        + incoming.manifest.schemaIDs.joined(separator: "、") + "）"]
      await redeployActiveProfile()
    } catch {
      errorMessage = "导入设置失败：" + String(describing: error)
    }
  }
}
