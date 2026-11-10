import RimeEngine
import SwiftUI

extension View {
  func settingsHelp<HelpContent: View>(@ViewBuilder content: @escaping () -> HelpContent) -> some View {
    modifier(SettingsHelpModifier(helpContent: content))
  }
}

/// Presents guidance without leaving the settings screen or disturbing its drafts.
private struct SettingsHelpModifier<HelpContent: View>: ViewModifier {
  @Environment(\.locale) private var interfaceLocale
  @State private var showingHelp = false
  let helpContent: () -> HelpContent

  func body(content: Content) -> some View {
    let _ = interfaceLocale
    content
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { showingHelp = true } label: {
            Label(RimeLocalization.text("Usage guide"), systemImage: "questionmark.circle")
              .labelStyle(.iconOnly)
          }
          .accessibilityIdentifier("settings-usage-guide")
        }
      }
      .sheet(isPresented: $showingHelp) {
        NavigationStack {
          List { helpContent() }
            .listStyle(.insetGrouped)
            .navigationTitle(RimeLocalization.text("Usage guide"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("settings-usage-guide-content")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button(RimeLocalization.text("Done")) { showingHelp = false }
                  .accessibilityIdentifier("settings-usage-guide-close")
              }
            }
        }
      }
  }
}
