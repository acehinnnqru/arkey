import Foundation

// MARK: - What is inside the binary

/// One component of the engine we ship, with its licence **only where it has been verified**.
///
/// S6-AC4 asks the notices to list librime and its third-party notices. Three of these are verified
/// from the pinned framework's own headers — librime's, and the packaging's, both of which state
/// BSD-3-Clause. The plugins the same headers say are merged (lua, octagram, predict) carry licences
/// this repository has not verified, so they are listed by name and upstream URL with the licence
/// deliberately **unsaid**: an invented SPDX identifier on a notices screen is worse than an honest
/// gap, because it is the one place a user goes to check.
public struct RimeComponentNotice: Sendable, Hashable {
  public let name: String
  public let version: String?
  /// The licence, when it has been read from the component's own distribution.
  public let license: String?
  public let url: String
  public let note: String?

  public init(name: String, version: String? = nil, license: String?, url: String,
              note: String? = nil) {
    self.name = name
    self.version = version
    self.license = license
    self.url = url
    self.note = note
  }

  public var line: String {
    var parts = [name]
    if let version { parts.append(version) }
    parts.append(license ?? RimeLocalization.text("See upstream for license"))
    return parts.joined(separator: " · ")
  }
}

public enum RimeEngineNotices {
  /// The engine and what the pinned build says it contains.
  public static func components(engineVersion: String = RimeEngineVersion.pinned) -> [RimeComponentNotice] {
    [
      .init(name: "librime", version: engineVersion, license: "BSD-3-Clause",
            url: "https://github.com/rime/librime",
            note: RimeLocalization.text("The engine linked by this app. Tables, prisms, and grammar models are mapped read only; the extension does not write them.")),
      .init(name: "librime-xcframework", version: "1.17.0-pack.9.0.2", license: "BSD-3-Clause",
            url: "https://github.com/ghostflyby/librime-xcframework",
            note: RimeLocalization.text("Framework distribution of librime and its plugins. Tables are produced by this version and require the same runtime.")),
      .init(name: "librime-lua", license: nil,
            url: "https://github.com/hchunhui/librime-lua",
            note: RimeLocalization.text("Bundled with the framework; runs Lua translators and filters from profiles. See upstream for license.")),
      .init(name: "octagram", license: nil,
            url: "https://github.com/lotem/librime-octagram",
            note: RimeLocalization.text("Bundled grammar model plugin. Disabled by default; models require a separate download. See upstream for license.")),
      .init(name: "predict", license: nil,
            url: "https://github.com/rime/librime-predict",
            note: RimeLocalization.text("Bundled prediction plugin. Disabled by default. See upstream for license.")),
    ]
  }

  /// Components whose licence this repository has not verified, so the screen can say how many and
  /// which — a count is checkable, a guess is not.
  public static func unverifiedLicenses(engineVersion: String = RimeEngineVersion.pinned) -> [String] {
    components(engineVersion: engineVersion).filter { $0.license == nil }.map(\.name)
  }
}
