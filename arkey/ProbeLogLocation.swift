import Foundation

/// Where the probe log lives, and how to get a copy somewhere a paired Mac can reach it.
///
/// The log itself belongs in the app group container, because the keyboard writes it. But
/// "devicectl device copy from --domain-type appGroupDataContainer" refuses that container with a
/// spurious path error, while the app's own container copies fine. So the app mirrors the log into
/// its Documents directory: opening the app is then enough for the log to be fetchable over USB,
/// without anyone copying text by hand.
enum ProbeLogLocation {
  static let appGroupID = "group.com.acehinnnqru.arkey"

  static var groupLogURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent("rime/log/probe.jsonl")
  }

  static var mirroredURL: URL? {
    FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask)
      .first?
      .appendingPathComponent("probe.jsonl")
  }

  /// Copies the shared log into the app container. Cheap enough to call on every app launch.
  static func mirrorIntoAppContainer() {
    guard let source = groupLogURL, let destination = mirroredURL else { return }
    guard let data = try? Data(contentsOf: source) else { return }
    try? data.write(to: destination, options: .atomic)
  }
}
