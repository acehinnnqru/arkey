import UIKit
import RimeEngine

/// The keyboard's geometry, from S3's measured style rather than from eyeballed values.
///
/// The tracer used 3 pt margins, 6 pt gaps and 48 pt keys; the captures say 8.3 / 9.7 / 45.0, and the
/// difference is visible the moment the two are side by side. Every number here comes from
/// `RimeKeyboardStyle.measured`, which carries the device and OS it was measured on, and the layout
/// itself is computed by `RimeKeyboardLayoutEngine` — these are the few values the views need before
/// a layout exists.
enum KeyboardMetrics {
  static var style: RimeKeyboardStyle { .measured }

  static var sideMargin: CGFloat { style.sideMargin }
  static var keyGap: CGFloat { style.horizontalGap }
  static var rowGap: CGFloat { style.rowGap }
  static var keyHeight: CGFloat { style.keyHeight }
  static var candidateBarHeight: CGFloat { style.candidateSlotHeight }
  static var globeRowHeight: CGFloat { style.globeRowHeight }
  static var bottomInset: CGFloat { style.bottomInset }
  static var cornerRadius: CGFloat { style.cornerRadius }

  /// The height the extension asks the system for. It is the layout engine's answer, so the frame the
  /// system animates and the frames the keys are drawn in cannot disagree — the class of bug that
  /// killed the tracer's extension.
  static func totalHeight(needsGlobeRow: Bool) -> CGFloat {
    RimeKeyboardLayoutEngine.layout(width: 430, layer: .letters, needsGlobeRow: needsGlobeRow,
                                    style: style).height
  }

  /// The same, for the width the keyboard actually has.
  static func totalHeight(width: CGFloat, needsGlobeRow: Bool) -> CGFloat {
    RimeKeyboardLayoutEngine.layout(width: max(width, 1), layer: .letters,
                                    needsGlobeRow: needsGlobeRow, style: style).height
  }
}

/// The keyboard's colours, from S3's measured palette.
///
/// The palette is the *fallback*: the backing should come from the system material
/// (`inputViewStyle = .keyboard`) when the host gives it, which is what `backingFollowsMaterial` records.
/// Everything else — key caps, the action key's two states, the glyph colour — is measured.
struct KeyboardTheme {
  let appearance: UIKeyboardAppearance
  private let palette: RimeKeyboardPalette

  static func current(for appearance: UIKeyboardAppearance) -> KeyboardTheme {
    KeyboardTheme(appearance: appearance)
  }

  private init(appearance: UIKeyboardAppearance) {
    self.appearance = appearance
    switch appearance {
    case .light:
      self.palette = .light
    case .dark, .alert:
      self.palette = .dark
    default:
      self.palette = .dark
    }
  }

  private static func color(_ value: RimeKeyboardPalette.Color) -> UIColor {
    UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
  }

  /// Only used when the material path is unavailable; the extension's root view is a `UIInputView` with
  /// `.keyboard` style, which is the documented way to get the system's own background.
  var background: UIColor { Self.color(palette.backing) }

  var backingFollowsMaterial: Bool { palette.backingFollowsMaterial }

  /// The cap colour for a role. Every fill below goes through here, so the *rule* lives in the engine and
  /// this file only converts the colour it returns (S3 §4; see docs/s3-results.md for why that mattered).
  func fill(for role: RimeKeyCapRole) -> UIColor {
    Self.color(role.colour(in: palette))
  }

  /// Letter keys — and in light mode every key, including shift, delete and the bottom row.
  var keyFill: UIColor { fill(for: .letter) }

  /// Shift, delete, 123, emoji and return.
  var specialKeyFill: UIColor { fill(for: .wide) }

  /// The pressed fill, which moves in opposite directions in the two appearances.
  func pressedFill(forWideKey isWide: Bool) -> UIColor {
    fill(for: isWide ? .pressedWide : .pressedLetter)
  }

  /// Shift while it is active.
  var activeKeyFill: UIColor { fill(for: .pressedLetter) }

  var keyText: UIColor { Self.color(palette.glyph) }

  var activeKeyText: UIColor { Self.color(palette.glyph) }

  /// The action key's two measured states (S3 §6).
  func returnKeyFill(isEnabled: Bool) -> UIColor {
    fill(for: isEnabled ? .actionEnabled : .actionDisabled)
  }

  var returnKeyText: UIColor { .white }

  /// The system keyboard has no drop shadow in dark mode and a soft one in light.
  var keyShadowOpacity: Float { palette.isDark ? 0 : 0.35 }

  var candidateText: UIColor { Self.color(palette.glyph) }

  var separator: UIColor {
    palette.isDark ? UIColor(white: 1, alpha: 0.18) : UIColor(white: 0, alpha: 0.18)
  }

  var candidateHighlightFill: UIColor {
    palette.isDark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08)
  }

  /// The expanded panel's selected cell: the capture shows a white rounded highlight on the grid,
  /// which is stronger than the collapsed bar's wash.
  var candidatePanelHighlightFill: UIColor {
    palette.isDark ? UIColor(white: 1, alpha: 0.22) : UIColor(white: 1, alpha: 0.95)
  }
}