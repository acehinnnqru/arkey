import SwiftUI

/// Settings owns its navigation so detail pages stay inside the drawer.
struct SettingsView: View {
  @ObservedObject var model: RimeAppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("Input") {
          NavigationLink { SchemaSettingsView(model: model) } label: {
            Label("方案与输入", systemImage: "character.bubble")
          }
          NavigationLink { KeyboardSettingsView(model: model) } label: {
            Label("键盘", systemImage: "keyboard")
          }
          NavigationLink { PunctuationView(model: model) } label: {
            Label("标点", systemImage: "textformat.123")
          }
          NavigationLink { KeyBindingsView(model: model) } label: {
            Label("按键", systemImage: "command")
          }
          NavigationLink { CustomPhraseView(model: model) } label: {
            Label("自定义短语", systemImage: "text.bubble")
          }
          NavigationLink { UserDictionaryView(model: model) } label: {
            Label("用户词库", systemImage: "book")
          }
        }

        Section("Profiles") {
          NavigationLink { ProfileLibraryView(model: model) } label: {
            Label("配置库", systemImage: "folder")
          }
          NavigationLink { CatalogView() } label: {
            Label("下载配置", systemImage: "arrow.down.circle")
          }
          NavigationLink { DeployView(model: model) } label: {
            Label("部署", systemImage: "arrow.triangle.2.circlepath")
          }
        }

        Section("About") {
          NavigationLink { NoticesView(model: model) } label: {
            Label("许可证", systemImage: "doc.text")
          }
          NavigationLink { DiagnosticsView() } label: {
            Label("诊断", systemImage: "stethoscope")
          }
        }
      }
      .listStyle(.insetGrouped)
      .accessibilityIdentifier("settings-list")
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("settings-close")
        }
      }
    }
  }
}
