import SwiftUI

/// What the user reads, as opposed to what the model holds.
///
/// The model keeps the whole sentence: tests assert on it, and the probe log is where internals belong. A
/// filesystem path is neither — one leaked into the UI next to a real failure ("the profile has no sources at
/// /Users/…/profiles//source"), and a path on a phone is meaningless to the person holding it. Every screen that
/// shows a message from the model goes through here, so the folding cannot be forgotten on one screen.
enum UserFacing {
  /// The message with absolute paths folded to "…/last". A path is two or more slash-separated components;
  /// config keys like translator/enable_user_dict have one and are left alone.
  static func text(_ raw: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "(?:/[A-Za-z0-9._+-]+){2,}") else { return raw }
    var result = raw
    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    for match in regex.matches(in: raw, range: range).reversed() {
      guard let swiftRange = Range(match.range, in: result) else { continue }
      let path = String(result[swiftRange])
      // The last component is the part that says *which* folder it is — …/ArkeySync tells the user something,
      // … tells them nothing.
      let tail = path.split(separator: "/").last.map(String.init) ?? ""
      result.replaceSubrange(swiftRange, with: tail.isEmpty ? "…" : "…/" + tail)
    }
    return result
  }

  /// The red error row nine screens were each writing for themselves.
  static func errorRow(_ raw: String) -> some View {
    Section("错误") {
      Text(text(raw)).font(.caption).foregroundStyle(.red)
    }
  }
}
