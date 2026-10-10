import RimeEngine
import SwiftUI

/// Settings owns its navigation so detail pages stay inside the drawer.
struct SettingsView: View {
  @Environment(\.locale) private var interfaceLocale
  @AppStorage(RimeLocalization.storageKey, store: UserDefaults(suiteName: RimeKeyboardPreferencesStore.appGroupID))
  private var interfaceLanguage = RimeAppLanguage.chinese.rawValue
  let model: RimeAppModel
  @Environment(\.dismiss) private var dismiss

  private enum Page: Hashable {
    case schema, keyboard, punctuation, keys, phrases, dictionaries
    case profiles, catalog, notices, diagnostics
  }

  var body: some View {
    let _ = interfaceLocale
    NavigationStack {
      List {
        Section {
          Picker(RimeLocalization.text("Interface language"), selection: Binding(
            get: { RimeAppLanguage.resolve(interfaceLanguage).rawValue },
            set: { interfaceLanguage = $0 })) {
            ForEach(RimeAppLanguage.allCases, id: \.rawValue) { language in
              Text(language.nativeName).tag(language.rawValue)
            }
          }
          .accessibilityIdentifier("interface-language")
        } header: {
          Text(RimeLocalization.text("Language"))
        } footer: {
          Text(RimeLocalization.text("Chinese is the default. The keyboard uses this language the next time it opens."))
        }
        Section(RimeLocalization.text("Input")) {
          NavigationLink(value: Page.schema) {
            Label(RimeLocalization.text("Scheme and input"), systemImage: "character.bubble")
          }
          NavigationLink(value: Page.keyboard) {
            Label(RimeLocalization.text("Keyboard"), systemImage: "keyboard")
          }
          NavigationLink(value: Page.punctuation) {
            Label(RimeLocalization.text("Punctuation"), systemImage: "textformat.123")
          }
          NavigationLink(value: Page.keys) {
            Label(RimeLocalization.text("Keys"), systemImage: "command")
          }
          NavigationLink(value: Page.phrases) {
            Label(RimeLocalization.text("Custom phrases"), systemImage: "text.bubble")
          }
          NavigationLink(value: Page.dictionaries) {
            Label(RimeLocalization.text("User dictionaries"), systemImage: "book")
          }
        }

        Section(RimeLocalization.text("Profiles")) {
          NavigationLink(value: Page.profiles) {
            Label(RimeLocalization.text("Profile library"), systemImage: "folder")
          }
          NavigationLink(value: Page.catalog) {
            Label(RimeLocalization.text("Download profiles"), systemImage: "arrow.down.circle")
          }
        }

        Section(RimeLocalization.text("About")) {
          NavigationLink(value: Page.notices) {
            Label(RimeLocalization.text("Licenses"), systemImage: "doc.text")
          }
          NavigationLink(value: Page.diagnostics) {
            Label(RimeLocalization.text("Diagnostics"), systemImage: "stethoscope")
          }
        }
      }
      .listStyle(.insetGrouped)
      .accessibilityIdentifier("settings-list")
      .navigationTitle(RimeLocalization.text("Settings"))
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
        case .notices: NoticesView(model: model)
        case .diagnostics: DiagnosticsView()
        }
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(RimeLocalization.text("Done")) { dismiss() }
            .accessibilityIdentifier("settings-close")
        }
      }
    }
  }
}
