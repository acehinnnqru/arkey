import UIKit

/// Experimental iOS 27 workaround. This tracks presentations across controller
/// replacement, not an observed host inset. It resets only with the process.
@MainActor
final class KeyboardReentryCompatibility {
  static let shared = KeyboardReentryCompatibility(
    isEnabled: ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27
      && UIDevice.current.userInterfaceIdiom == .phone)

  let isEnabled: Bool
  private(set) var presentationCount = 0

  nonisolated init(isEnabled: Bool) {
    self.isEnabled = isEnabled
  }

  var nextTopReduction: CGFloat {
    isEnabled && presentationCount > 0 ? 17 : 0
  }

  func beginPresentation() -> (number: Int, topReduction: CGFloat) {
    let reduction = nextTopReduction
    presentationCount += 1
    return (presentationCount, reduction)
  }
}
