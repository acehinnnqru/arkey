import SwiftUI
import RimeEngine
import UIKit

/// The host app exists to give the keyboard somewhere to type, and to own everything the keyboard
/// must not do itself: import, deploy, activate, and say why.
///
/// The text field owns the screen: a keyboard, custom or not, must never push it out of sight.
struct ContentView: View {
  @StateObject private var model = RimeAppModel.shared
  @State private var text = ""
  @State private var keyboardOverlap: CGFloat = 0
  @State private var isShowingSettings = false
  @FocusState private var isEditing: Bool

  var body: some View {
    NavigationStack {
      GeometryReader { _ in
      VStack(alignment: .leading, spacing: 10) {
        Text("在下面的输入框里切换到 Arkey 键盘试试。")
          .font(.footnote)
          .foregroundStyle(.secondary)

        TextEditor(text: $text)
          .font(.system(size: 20))
          .focused($isEditing)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay {
            RoundedRectangle(cornerRadius: 10)
              .stroke(.quaternary)
          }

        // The same engine and the same profile the keyboard uses, so a failure here is a failure
        // there — and the profile line says which of the three states is in effect (S1 §9).
        VStack(alignment: .leading, spacing: 2) {
          Text(model.resolvedSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Text(model.engineStatus)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        // S1 §9: the degraded state names the repair *and* offers it. The action decides the screen,
        // so the button cannot lead somewhere that does not fix the problem it just described.
        if let recovery = model.recovery {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(recovery.message, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
              .lineLimit(3)
            Spacer(minLength: 0)
            NavigationLink(recovery.action.title) {
              switch recovery.action {
              case .deploy: DeployView(model: model)
              case .chooseProfile: ProfileLibraryView(model: model)
              }
            }
            .font(.caption.bold())
            .buttonStyle(.borderedProminent)
          }
        }
      }
      .padding()
      .padding(.bottom, keyboardOverlap)
      }
      .background(KeyboardOverlapReader { keyboardOverlap = $0 })
      .ignoresSafeArea(.keyboard, edges: .bottom)
      .navigationTitle("Arkey")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          NavigationLink("键盘") { KeyboardPreviewScreen(model: model) }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            isEditing = false
            isShowingSettings = true
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
          .accessibilityIdentifier("settings-open")
        }
      }
      .sheet(isPresented: $isShowingSettings) {
        SettingsView(model: model)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
      }
      .onAppear {
        LaunchProbe.mark("viewAppear")
      }
      .task {
        // Bootstrap is a diagnostic plus the workspace seeding, not startup work: entering the app
        // never waits for librime, and the field is not focused automatically because that spawns
        // the keyboard extension on the launch path too.
        LaunchProbe.mark("bootstrapStart")
        await model.bootstrap()
        LaunchProbe.mark("checkDone")
        LaunchProbe.flush()
      }
    }
  }

}

#Preview {
  ContentView()
}
