import SwiftUI

/// Settings owns its navigation so detail pages stay inside the drawer.
struct SettingsView: View {
  let model: RimeAppModel
  @Environment(\.dismiss) private var dismiss

  private enum Page: Hashable {
    case schema, keyboard, punctuation, keys, phrases, dictionaries
    case profiles, catalog, deploy, notices, diagnostics
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Input") {
          NavigationLink(value: Page.schema) {
            Label("方案与输入", systemImage: "character.bubble")
          }
          NavigationLink(value: Page.keyboard) {
            Label("键盘", systemImage: "keyboard")
          }
          NavigationLink(value: Page.punctuation) {
            Label("标点", systemImage: "textformat.123")
          }
          NavigationLink(value: Page.keys) {
            Label("按键", systemImage: "command")
          }
          NavigationLink(value: Page.phrases) {
            Label("自定义短语", systemImage: "text.bubble")
          }
          NavigationLink(value: Page.dictionaries) {
            Label("用户词库", systemImage: "book")
          }
        }

        Section("Profiles") {
          NavigationLink(value: Page.profiles) {
            Label("配置库", systemImage: "folder")
          }
          NavigationLink(value: Page.catalog) {
            Label("下载配置", systemImage: "arrow.down.circle")
          }
          NavigationLink(value: Page.deploy) {
            Label("部署", systemImage: "arrow.triangle.2.circlepath")
          }
        }

        Section("About") {
          NavigationLink(value: Page.notices) {
            Label("许可证", systemImage: "doc.text")
          }
          NavigationLink(value: Page.diagnostics) {
            Label("诊断", systemImage: "stethoscope")
          }
        }
      }
      .listStyle(.insetGrouped)
      .accessibilityIdentifier("settings-list")
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: Page.self) { page in
        switch page {
        case .schema: SchemaSettingsView(model: model)
        case .keyboard: KeyboardSettingsView(model: model)
        case .punctuation: PunctuationView(model: model)
        case .keys: KeyBindingsView(model: model)
        case .phrases: CustomPhraseView(model: model)
        case .dictionaries: UserDictionaryView(model: model)
        case .profiles: ProfileLibraryView(model: model)
        case .catalog: CatalogView()
        case .deploy: DeployView(model: model)
        case .notices: NoticesView(model: model)
        case .diagnostics: DiagnosticsView()
        }
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("settings-close")
        }
      }
    }
  }
}
