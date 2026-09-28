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
  var body: some View {
    List {
      Section {
        ForEach(RimeCatalog.standard.entries, id: \.id) { entry in
          row(entry)
        }
      } header: {
        Text("可选配置")
      } footer: {
        Text("下载在系统浏览器里进行；下载完成后回到「配置库 → 导入」把 zip 装进来。"
             + "本 app 自己不发起网络请求，也不托管任何第三方数据。")
      }
      Section("导入") {
        Text("导入走的是同一条管线：解包加固、配置根识别、逐文件校验，失败时指名文件与原因。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("下载配置")
  }

  private func row(_ entry: RimeCatalogEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.displayName).font(.body.weight(.medium))
      Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
      Text(entry.notes).font(.caption2).foregroundStyle(.secondary)
      HStack(spacing: 14) {
        if entry.isSecure, let url = URL(string: entry.pageURL) {
          Link("打开项目页", destination: url).font(.caption)
        } else {
          Text("项目页地址不是 HTTPS，已隐藏").font(.caption).foregroundStyle(.orange)
        }
        if let source = entry.license.sourceURL, let url = URL(string: source) {
          Link("上游仓库", destination: url).font(.caption)
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
                 String(entry.requirements.schemaCount) + " 个方案"]
    if entry.requirements.needsLua { parts.append("含 Lua") }
    if entry.requirements.needsGrammarModel { parts.append("含语法模型") }
    if entry.requirements.needsPredict { parts.append("含预测") }
    return parts.joined(separator: " · ")
  }
}
