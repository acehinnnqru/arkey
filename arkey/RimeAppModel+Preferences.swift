import Combine
import Foundation
import RimeEngine
import SwiftUI

/// The keyboard's own settings (S2 §3's last row, S3 §4/§5).
///
/// These are not Rime configuration: they never become a patch and never need a deploy. They go to
/// the app group's `UserDefaults` so the keyboard sees them the next time it appears — see
/// `RimeKeyboardPreferencesStore` for why that is also why the privacy manifest declares
/// `NSPrivacyAccessedAPICategoryUserDefaults`.
@MainActor
extension RimeAppModel {
  var preferencesStore: RimeKeyboardPreferencesStore? {
    RimeKeyboardPreferencesStore.appGroup()
  }

  func refreshPreferences() {
    keyboardPreferences = preferencesStore?.value ?? .standard
  }

  func updatePreferences(_ transform: (inout RimeKeyboardPreferences) -> Void) {
    guard let store = preferencesStore else {
      errorMessage = "拿不到 App Group，键盘设置无法共享给键盘。"
      return
    }
    var preferences = store.value
    transform(&preferences)
    store.value = preferences
    keyboardPreferences = preferences
  }

  func resetPreferences() {
    preferencesStore?.reset()
    refreshPreferences()
  }
}
