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
  @State private var keyboardHeight: CGFloat = 0
  @FocusState private var isEditing: Bool

  var body: some View {
    NavigationStack {
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
      // Third-party keyboards need explicit avoidance after returning from navigation.
      .padding(.bottom, keyboardHeight)
      .ignoresSafeArea(.keyboard, edges: .bottom)
      .navigationTitle("Arkey")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          NavigationLink("键盘") { KeyboardPreviewScreen(model: model) }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            NavigationLink("配置库") { ProfileLibraryView(model: model) }
            NavigationLink("下载配置") { CatalogView() }
            NavigationLink("方案与输入") { SchemaSettingsView(model: model) }
            NavigationLink("用户词库") { UserDictionaryView(model: model) }
            NavigationLink("键盘") { KeyboardSettingsView(model: model) }
            NavigationLink("标点") { PunctuationView(model: model) }
            NavigationLink("按键") { KeyBindingsView(model: model) }
            NavigationLink("自定义短语") { CustomPhraseView(model: model) }
            NavigationLink("部署") { DeployView(model: model) }
            NavigationLink("许可证") { NoticesView(model: model) }
            NavigationLink("诊断") { DiagnosticsView() }
          } label: {
            Label("更多", systemImage: "ellipsis.circle")
          }
        }
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
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
        updateKeyboardHeight($0)
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) {
        updateKeyboardHeight($0, hiding: true)
      }
    }
  }

  private func updateKeyboardHeight(_ notification: Notification, hiding: Bool = false) {
    let info = notification.userInfo ?? [:]
    let height: CGFloat
    if hiding {
      height = 0
    } else {
      guard let frame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
      let screenHeight = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
        .first ?? frame.maxY
      height = max(0, screenHeight - frame.minY)
    }
    guard height != keyboardHeight else { return }
    let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
    let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? 0
    let animation: Animation
    switch curve {
    case UIView.AnimationCurve.easeIn.rawValue: animation = .easeIn(duration: duration)
    case UIView.AnimationCurve.easeOut.rawValue: animation = .easeOut(duration: duration)
    case UIView.AnimationCurve.linear.rawValue: animation = .linear(duration: duration)
    default: animation = .easeInOut(duration: duration)
    }
    // A zero-duration frame update (for example an interactive transition) stays immediate.
    withAnimation(duration > 0 ? animation : nil) {
      keyboardHeight = height
    }
  }
}

#Preview {
  ContentView()
}
