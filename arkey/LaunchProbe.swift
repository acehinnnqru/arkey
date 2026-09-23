import Foundation
import RimeEngine

/// Records where the app's launch time goes. "The app is slow to open" is not actionable on its
/// own, so each step logs the delta from the previous mark and the total since the first one.
///
/// The first version of this trapped on launch: it captured "now" before touching the static that
/// "lastMark" was initialised from, so the subtraction ran backwards and underflowed a UInt64.
/// The arithmetic below cannot trap whatever order the marks arrive in.
enum LaunchProbe {
  private static var startNanoseconds: UInt64?
  private static var lastNanoseconds: UInt64?
  private static var marks: [String] = []

  static func mark(_ name: String) {
    let now = DispatchTime.now().uptimeNanoseconds
    let start = startNanoseconds ?? now
    startNanoseconds = start
    let previous = lastNanoseconds ?? start
    lastNanoseconds = now

    var text = name + "=+" + milliseconds(previous, now) + "ms"
      + "(total=" + milliseconds(start, now) + "ms"
    // The process age is what includes dyld and everything before our first line of code.
    if let age = RimeProbe.processAgeSeconds() {
      text += " age=" + format(age * 1000) + "ms"
    }
    text += ")"
    marks.append(text)
  }

  /// Writes one record and resets, so a later call cannot duplicate the timeline.
  static func flush() {
    guard !marks.isEmpty else { return }
    let message = marks.joined(separator: " ")
    marks = []
    guard let shared = RimeDirectories.bundledSharedDataURL(),
          let directories = try? RimeDirectories.resolve(appGroupID: "group.com.acehinnnqru.arkey",
                                                         sharedDataURL: shared) else { return }
    let url = URL(fileURLWithPath: directories.logDir, isDirectory: true)
      .appendingPathComponent("probe.jsonl")
    RimeProbeLog(url: url).append(RimeProbeRecord(phase: "app.launch", message: message))
    ProbeLogLocation.mirrorIntoAppContainer()
  }

  private static func milliseconds(_ from: UInt64, _ to: UInt64) -> String {
    format(to > from ? Double(to - from) / 1_000_000 : 0)
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.0f", value)
  }
}
