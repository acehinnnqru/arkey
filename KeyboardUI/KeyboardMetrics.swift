import UIKit
import RimeEngine

/// Shared geometry for the extension and in-app preview.
enum KeyboardMetrics {
  static var style: RimeKeyboardStyle { .systemAligned }

  static var sideMargin: CGFloat { style.sideMargin }
  static var keyGap: CGFloat { style.horizontalGap }
  static var rowGap: CGFloat { style.rowGap }
  static var keyHeight: CGFloat { style.keyHeight }
  static var candidateBarHeight: CGFloat { extensionStyle.candidateSlotHeight }
  static let candidateTextLeading: CGFloat = 12
  static let candidateTextOffset: CGFloat = 0
  static var candidateTextCenterY: CGFloat { candidateBarHeight / 2 + candidateTextOffset }
  static var keyBottomPadding: CGFloat { extensionStyle.bottomInset }
  static var globeRowHeight: CGFloat { style.globeRowHeight }
  static var bottomInset: CGFloat { style.bottomInset }
  static var cornerRadius: CGFloat { style.cornerRadius }

  /// The height the extension asks the system for. It is the layout engine's answer, so the frame the
  /// system animates and the frames the keys are drawn in cannot disagree — the class of bug that
  /// killed the tracer's extension.
  /// The candidate slot belongs entirely to the extension. A host band observed
  /// after navigation is not a reliable inset, particularly on first presentation.
  /// Keep the reference candidate slot and five points below the last row.
  /// The full native bottom inset belongs to the host and must never be counted here again.
  static var extensionStyle: RimeKeyboardStyle {
    var style = self.style
    style.bottomInset = 5
    return style
  }

  static func totalHeight(needsGlobeRow: Bool) -> CGFloat {
    RimeKeyboardLayoutEngine.layout(width: 430, layer: .letters, needsGlobeRow: needsGlobeRow,
                                    style: extensionStyle).height
  }

  /// The same, for the width the keyboard actually has.
  static func totalHeight(width: CGFloat, needsGlobeRow: Bool) -> CGFloat {
    RimeKeyboardLayoutEngine.layout(width: max(width, 1), layer: .letters,
                                    needsGlobeRow: needsGlobeRow, style: extensionStyle).height
  }
}

/// The keyboard's colours, from S3's measured palette.
///
/// The extension and preview paint an opaque content backing so an outgoing
/// input mode cannot show through the keys. The host owns the bottom system strip.
/// Everything else — key caps, the action key's two states, the glyph colour — is measured.
struct KeyboardTheme {
  let appearance: UIKeyboardAppearance
  private let palette: RimeKeyboardPalette

  /// Losing the text client during a navigation transition is not a theme change.
  /// Resolve a real default appearance from traits, and retain the last palette
  /// while the proxy temporarily has no appearance to report.
  static func current(for appearance: UIKeyboardAppearance?,
                      interfaceStyle: UIUserInterfaceStyle = .unspecified,
                      previous: KeyboardTheme? = nil) -> KeyboardTheme {
    guard let appearance else {
      return previous ?? current(for: .default, interfaceStyle: interfaceStyle)
    }
    let resolved: UIKeyboardAppearance
    switch appearance {
    case .light: resolved = .light
    case .dark, .alert: resolved = .dark
    default:
      switch interfaceStyle {
      case .dark: resolved = .dark
      case .light: resolved = .light
      default: resolved = previous?.appearance ?? .light
      }
    }
    return KeyboardTheme(appearance: resolved)
  }

  private init(appearance: UIKeyboardAppearance) {
    self.appearance = appearance
    self.palette = appearance == .dark ? .dark : .light
  }

  private static func color(_ value: RimeKeyboardPalette.Color) -> UIColor {
    UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
  }

  /// Solid backing for keyboard content and standalone previews.
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

  /// Flat caps: a hard bottom shadow makes the wider keys look raised.
  var keyShadowOpacity: Float { 0 }

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
