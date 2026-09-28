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
    parts.append(license ?? "许可证见上游")
    return parts.joined(separator: " · ")
  }
}

public enum RimeEngineNotices {
  /// The engine and what the pinned build says it contains.
  public static func components(engineVersion: String = RimeEngineVersion.pinned) -> [RimeComponentNotice] {
    [
      .init(name: "librime", version: engineVersion, license: "BSD-3-Clause",
            url: "https://github.com/rime/librime",
            note: "本项目链接的引擎。表、棱镜与语法模型以只读方式映射，扩展不写它。"),
      .init(name: "librime-xcframework", version: "1.17.0-pack.9.0.2", license: "BSD-3-Clause",
            url: "https://github.com/ghostflyby/librime-xcframework",
            note: "把 librime 及其插件打包成框架的发行版；表由该版本产出，运行时必须与之一致。"),
      .init(name: "librime-lua", license: nil,
            url: "https://github.com/hchunhui/librime-lua",
            note: "随框架合入：配置里的 Lua 翻译器与滤镜由它执行。许可证见上游。"),
      .init(name: "octagram", license: nil,
            url: "https://github.com/lotem/librime-octagram",
            note: "随框架合入：语法模型插件。默认关闭，模型需另行下载。许可证见上游。"),
      .init(name: "predict", license: nil,
            url: "https://github.com/rime/librime-predict",
            note: "随框架合入：预测插件。默认关闭。许可证见上游。"),
    ]
  }

  /// Components whose licence this repository has not verified, so the screen can say how many and
  /// which — a count is checkable, a guess is not.
  public static func unverifiedLicenses(engineVersion: String = RimeEngineVersion.pinned) -> [String] {
    components(engineVersion: engineVersion).filter { $0.license == nil }.map(\.name)
  }
}
