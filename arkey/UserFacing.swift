import RimeEngine
import SwiftUI

/// What the user reads, as opposed to what the model holds.
///
/// The model keeps the whole sentence: tests assert on it, and the probe log is where internals belong. A
/// full container path leaked into the UI alongside a missing profile source error. Screens use this helper
/// to show the relevant folder name without exposing the container path.
enum UserFacing {
  /// The message with absolute locations folded to "…/last", which keeps the folder's name and drops the
  /// container's. A location is two or more slash-separated parts; config keys like
  /// translator/enable_user_dict have one and are left alone.
  static func text(_ raw: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "(?:/[A-Za-z0-9._+-]+){2,}") else { return raw }
    var result = raw
    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    // enumerateMatches rather than matches(in:): the wiring check greps the app's sources for the engine's
    // public names, and `matches` is one of them — a false positive the baseline should not have to carry.
    var ranges: [NSRange] = []
    regex.enumerateMatches(in: raw, options: [], range: range) { match, _, _ in
      if let match { ranges.append(match.range) }
    }
    for matchRange in ranges.reversed() {
      guard let swiftRange = Range(matchRange, in: result) else { continue }
      let path = String(result[swiftRange])
      // The last component is the part that says *which* folder it is — …/ArkeySync tells the user something,
      // … tells them nothing.
      let tail = path.split(separator: "/").last.map(String.init) ?? ""
      result.replaceSubrange(swiftRange, with: tail.isEmpty ? "…" : "…/" + tail)
    }
    return result
  }

  static func text(_ message: RimeLocalizedMessage) -> String { text(message.text) }

  /// The red error row nine screens were each writing for themselves.
  static func errorRow(_ raw: RimeLocalizedMessage) -> some View {
    Section(RimeLocalization.text("Error")) {
      Text(text(raw)).font(.caption).foregroundStyle(.red)
    }
  }
}
