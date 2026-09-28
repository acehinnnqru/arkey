import Foundation

// MARK: - Degraded activation

/// S1 §9's last clause: when a profile cannot be activated the *screen that has the problem* has to say so
/// and say what fixes it. The keyboard cannot deploy and the app can, so this is about the action the user
/// takes, not the one the process would take — and it is one table, read by both surfaces, so the keyboard
/// never contradicts the app.
public struct RimeProfileRecovery: Sendable, Hashable {
  public enum Action: String, Sendable, Hashable {
    /// The app has a profile with a missing or stale build: deploying it again is the repair.
    case deploy
    /// There is no profile to deploy: the app has to import one or point `active.json` at one.
    case chooseProfile

    /// The action as a button reads it. It lives here so the keyboard's message and the app's button
    /// cannot describe the same repair in two different ways.
    public var title: String {
      switch self {
      case .deploy: return "重新部署"
      case .chooseProfile: return "导入或选择配置"
      }
    }
  }

  /// Why the process is not on a profile, in the resolver's own words (the probe log keeps the same text).
  public let reason: String
  /// What the user should read.
  public let message: String
  /// What the app has to offer them.
  public let action: Action

  public init(reason: String, message: String, action: Action) {
    self.reason = reason
    self.message = message
    self.action = action
  }

  /// Nil when a profile was activated. `fallbackReason` rather than `isDegraded` is the test: falling back
  /// to the *previous generation* still runs from the profile, and still needs the repair said out loud.
  public static func of(_ resolved: RimeResolvedProfile) -> RimeProfileRecovery? {
    guard let reason = resolved.fallbackReason else { return nil }

    if reason.hasPrefix("the active build is missing or empty") {
      return RimeProfileRecovery(reason: reason,
                                 message: "正在使用上一代编译数据；打开 Arkey 重新部署可修复",
                                 action: .deploy)
    }
    if reason.hasSuffix("has no usable build") {
      return RimeProfileRecovery(reason: reason,
                                 message: "当前配置没有可用的编译数据，键盘正在使用内置数据；打开 Arkey 重新部署",
                                 action: .deploy)
    }
    if reason.hasPrefix("no active.json") {
      return RimeProfileRecovery(reason: reason,
                                 message: "尚未选定配置，键盘正在使用内置数据；打开 Arkey 导入或选择配置",
                                 action: .chooseProfile)
    }
    if reason.hasPrefix("active.json") {
      return RimeProfileRecovery(reason: reason,
                                 message: "配置状态文件无法读取，键盘正在使用内置数据；打开 Arkey 重新选择配置",
                                 action: .chooseProfile)
    }
    return RimeProfileRecovery(reason: reason,
                               message: "配置不可用，键盘正在使用内置数据；打开 Arkey 检查",
                               action: .chooseProfile)
  }
}
