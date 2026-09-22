import SwiftUI
import RimeEngine

/// The host app exists to give the keyboard somewhere to type, and later to hold schema
/// management and the probe log viewer.
struct ContentView: View {
  @State private var text = ""
  @State private var engineStatus = "engine check running..."
  @FocusState private var isEditing: Bool

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("键盘外观预览（与扩展共用同一套视图代码）")
            .font(.footnote)
            .foregroundStyle(.secondary)
          KeyboardPreview()
            .frame(height: KeyboardMetrics.totalHeight(needsGlobeRow: true))
            .clipShape(RoundedRectangle(cornerRadius: 10))

          Text("在下面的输入框里切换到 Arkey 键盘试试。")
            .font(.footnote)
            .foregroundStyle(.secondary)
          TextEditor(text: $text)
            .font(.system(size: 20))
            .focused($isEditing)
            .frame(height: 140)
            .overlay {
              RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary)
            }
          // Same engine the keyboard uses, so a failure here is a failure there.
          Text(engineStatus)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding()
      }
      .navigationTitle("Arkey")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink("诊断") { DiagnosticsView() }
        }
      }
      .task {
        engineStatus = await EngineCheck.run()
      }
    }
  }
}

/// Runs the tracer's vertical slice inside the iOS app sandbox: resolve directories, start
/// librime, type nihao against the prebuilt tables shipped in the bundle, commit the candidate.
enum EngineCheck {
  static func run() async -> String {
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
      let start = try await engine.start()
      try await engine.openSession()
      let composing = try await engine.processKeys("nihao")
      let candidate = composing.candidates.first?.text ?? "(no candidate)"
      let committed = try await engine.selectCandidate(at: 0).commit ?? "(no commit)"
      await engine.shutdown()
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
