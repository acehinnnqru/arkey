import RimeEngine
import SwiftUI

/// Keeps the list mounted without exposing placeholder values or shifting its rows on completion.
struct SettingsLoadingPresentation: ViewModifier {
  @Environment(\.locale) private var interfaceLocale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsIndicator = false
  let isLoading: Bool

  func body(content: Content) -> some View {
    let _ = interfaceLocale
    content
      .disabled(isLoading)
      .accessibilityHidden(isLoading)
      .opacity(isLoading ? 0 : 1)
      .overlay {
        if isLoading && showsIndicator {
          VStack(spacing: 12) {
            ProgressView()
            Text(RimeLocalization.text("Loading settings…"))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .combine)
          .transition(.opacity)
        }
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isLoading)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsIndicator)
      .task(id: isLoading) {
        showsIndicator = false
        guard isLoading else { return }
        // A quick read should reveal the settings without flashing a spinner.
        do {
          try await Task.sleep(for: .milliseconds(150))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        showsIndicator = true
      }
  }
}
