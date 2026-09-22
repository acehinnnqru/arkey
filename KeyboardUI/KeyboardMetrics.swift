import UIKit

/// Metrics measured off the system keyboard on an iPhone 15 Pro Max screenshot, so the key
/// grid reads as native rather than as a lookalike.
enum KeyboardMetrics {
  static let sideMargin: CGFloat = 3
  static let keyGap: CGFloat = 6
  static let rowGap: CGFloat = 10
  static let keyHeight: CGFloat = 48
  static let candidateBarHeight: CGFloat = 44
  static let globeRowHeight: CGFloat = 40
  static let bottomInset: CGFloat = 8
  static let cornerRadius: CGFloat = 5

  /// Candidate bar, four key rows, and the globe row when the system asks for it.
  static func totalHeight(needsGlobeRow: Bool) -> CGFloat {
    var height = candidateBarHeight + rowGap
    height += 4 * keyHeight + 3 * rowGap
    if needsGlobeRow {
      height += rowGap + globeRowHeight
    }
    return height + bottomInset
  }
}

/// Colors per keyboard appearance. Values are eyeballed off the system keyboard in both modes.
struct KeyboardTheme {
  let appearance: UIKeyboardAppearance

  static func current(for appearance: UIKeyboardAppearance) -> KeyboardTheme {
    KeyboardTheme(appearance: appearance)
  }

  private var isDark: Bool {
    switch appearance {
    case .light: return false
    default: return true
    }
  }

  var background: UIColor {
    isDark ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1)
  }

  /// Letter, space and aux-code keys.
  var keyFill: UIColor {
    isDark ? UIColor(white: 0.42, alpha: 1) : .white
  }

  /// Shift, delete, 123, emoji and return.
  var specialKeyFill: UIColor {
    isDark ? UIColor(white: 0.25, alpha: 1) : UIColor(red: 0.68, green: 0.71, blue: 0.75, alpha: 1)
  }

  /// Shift while ascii mode is on, matching the light shift cap of the system keyboard.
  var activeKeyFill: UIColor {
    isDark ? UIColor(white: 0.85, alpha: 1) : .white
  }

  var keyText: UIColor {
    isDark ? .white : .black
  }

  var activeKeyText: UIColor {
    .black
  }

  var keyShadowOpacity: Float {
    isDark ? 0 : 0.35
  }

  var candidateText: UIColor {
    isDark ? .white : .black
  }

  var separator: UIColor {
    isDark ? UIColor(white: 1, alpha: 0.18) : UIColor(white: 0, alpha: 0.18)
  }

  var candidateHighlightFill: UIColor {
    isDark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08)
  }
}
