import SwiftUI
import RimeEngine
import UIKit

/// The host app exists to give the keyboard somewhere to type, and to hold the diagnostics.
/// The text field owns the screen: a keyboard, custom or not, must never push it out of sight.
struct ContentView: View {
  @State private var text = ""
  @State private var engineStatus = "engine check running..."
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

        // Same engine the keyboard uses, so a failure here is a failure there.
        Text(engineStatus)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding()
      // The system announces the keyboard frame, but a third-party keyboard is not always
      // reported the way the automatic avoidance expects, so the inset is applied explicitly.
      .padding(.bottom, keyboardHeight)
      .ignoresSafeArea(.keyboard, edges: .bottom)
      .navigationTitle("Arkey")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          NavigationLink("键盘") { KeyboardPreviewScreen() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink("诊断") { DiagnosticsView() }
        }
      }
      .task {
        engineStatus = EngineCheck.run()
        isEditing = true
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
          return
        }
        let screenHeight = UIApplication.shared.connectedScenes
          .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
          .first ?? frame.maxY
        keyboardHeight = max(0, screenHeight - frame.origin.y)
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
        keyboardHeight = 0
      }
    }
  }
}

/// Runs the tracer's vertical slice inside the iOS app sandbox: resolve directories, start
/// librime, type nihao against the prebuilt tables shipped in the bundle, commit the candidate.
enum EngineCheck {
  static func run() -> String {
    do {
      guard let shared = RimeDirectories.bundledSharedDataURL() else {
        return "RimeData missing from the bundle"
      }
      let directories = try RimeDirectories.resolve(appGroupID: "group.com.acehinnnqru.arkey",
                                                    sharedDataURL: shared)
      let probeURL = URL(fileURLWithPath: directories.logDir, isDirectory: true)
        .appendingPathComponent("probe.jsonl")
      let probe = RimeProbeLog(url: probeURL)
      let engine = RimeEngine(configuration: RimeConfiguration(directories: directories),
                              probeLog: probe)
      let start = try engine.start()
      try engine.openSession()
      let composing = try engine.processKeys("nihao")
      let candidate = composing.candidates.first?.text ?? "(no candidate)"
      let committed = try engine.selectCandidate(at: 0).commit ?? "(no commit)"
      engine.shutdown()
      let ms = Int(start.milliseconds ?? 0)
      probe.append(RimeProbeRecord(phase: "app.check", milliseconds: start.milliseconds,
                                   message: "root=" + directories.writableRoot.rawValue
                                     + " nihao -> " + candidate + " -> " + committed))
      return "librime " + RimeEngine.librimeVersion + "  root=" + directories.writableRoot.rawValue
        + "  init=" + String(ms) + "ms  nihao -> " + candidate + " -> " + committed
    } catch {
      return "engine error: " + String(describing: error)
    }
  }
}

#Preview {
  ContentView()
}
