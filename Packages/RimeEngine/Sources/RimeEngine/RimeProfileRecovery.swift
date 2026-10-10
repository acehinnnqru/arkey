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
      case .deploy: return RimeLocalization.text("Redeploy")
      case .chooseProfile: return RimeLocalization.text("Import or choose a profile")
      }
    }
  }

  /// Why the process is not on a profile, in the resolver's own words (the probe log keeps the same text).
  public let reason: String
  /// What the user should read.
  public let localizedMessage: RimeLocalizedMessage
  public var message: String { localizedMessage.text }
  /// What the app has to offer them.
  public let action: Action

  public init(reason: String, message: RimeLocalizedMessage, action: Action) {
    self.reason = reason
    self.localizedMessage = message
    self.action = action
  }

  /// Nil when a profile was activated. `fallbackReason` rather than `isDegraded` is the test: falling back
  /// to the *previous generation* still runs from the profile, and still needs the repair said out loud.
  public static func of(_ resolved: RimeResolvedProfile) -> RimeProfileRecovery? {
    guard let reason = resolved.fallbackReason else { return nil }

    if reason.hasPrefix("the active build is missing or empty") {
      return RimeProfileRecovery(reason: reason,
                                 message: RimeLocalization.message("Using the previous build. Open Arkey and redeploy to repair it."),
                                 action: .deploy)
    }
    if reason.hasSuffix("has no usable build") {
      return RimeProfileRecovery(reason: reason,
                                 message: RimeLocalization.message("This profile has no usable build. The keyboard uses built-in data. Open Arkey and redeploy."),
                                 action: .deploy)
    }
    if reason.hasPrefix("no active.json") {
      return RimeProfileRecovery(reason: reason,
                                 message: RimeLocalization.message("No profile is selected. The keyboard uses built-in data. Open Arkey to import or choose a profile."),
                                 action: .chooseProfile)
    }
    if reason.hasPrefix("active.json") {
      return RimeProfileRecovery(reason: reason,
                                 message: RimeLocalization.message("Profile state could not be read. The keyboard uses built-in data. Open Arkey and choose a profile again."),
                                 action: .chooseProfile)
    }
    return RimeProfileRecovery(reason: reason,
                               message: RimeLocalization.message("Profile unavailable. The keyboard uses built-in data. Open Arkey to check it."),
                               action: .chooseProfile)
  }
}
