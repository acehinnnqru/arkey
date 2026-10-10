import CoreGraphics
import Foundation

// MARK: - Palette

/// S3 §4: the measured colours, with their provenance, and the decision about the backing made
/// explicit rather than implied.
///
/// The backing is a *material* on iOS 26, so its measured value is only valid over that capture's
/// host. The recommended path is to let the system supply it — the keyboard's root view is a
/// `UIInputView` with `inputViewStyle = .keyboard` — and to keep these values as the fallback for a
/// fixed palette. `backingFollowsMaterial` is that decision, as data, so the overlay harness can
/// compare both without a rebuild.
public struct RimeKeyboardPalette: Sendable, Hashable {
  public struct Color: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
      self.red = red
      self.green = green
      self.blue = blue
      self.alpha = alpha
    }

    /// `0xRRGGBB`, which is how the captures are written down.
    public init(hex: UInt32, alpha: Double = 1) {
      self.red = Double((hex >> 16) & 0xFF) / 255
      self.green = Double((hex >> 8) & 0xFF) / 255
      self.blue = Double(hex & 0xFF) / 255
      self.alpha = alpha
    }

    public var hex: UInt32 {
      let r = UInt32((red * 255).rounded())
      let g = UInt32((green * 255).rounded())
      let b = UInt32((blue * 255).rounded())
      return (r << 16) | (g << 8) | b
    }
  }

  public let isDark: Bool
  public let backing: Color
  /// Letter keys, and in light mode every key including shift, delete and the bottom row.
  public let keyCap: Color
  /// The wider keys in dark mode, which are slightly lighter than letter keys. In light mode this is
  /// the same white as everything else — the opposite of the legacy keyboard's rules.
  public let wideKeyCap: Color
  public let pressedKeyCap: Color
  public let pressedWideKeyCap: Color
  public let actionEnabled: Color
  public let actionDisabled: Color
  public let glyph: Color
  /// True when the backing comes from the system material rather than from `backing`.
  public let backingFollowsMaterial: Bool

  public static let light = RimeKeyboardPalette(
    isDark: false,
    backing: Color(hex: 0xDEDFE4),
    keyCap: Color(hex: 0xFEFEFE),
    wideKeyCap: Color(hex: 0xFEFEFE),
    pressedKeyCap: Color(hex: 0xD9DADE),
    // From white the only way is darker; the "opposite direction" rule has no room in light mode.
    pressedWideKeyCap: Color(hex: 0xE6E7EA),
    actionEnabled: Color(hex: 0x3378F4),
    actionDisabled: Color(hex: 0xB0B3B8),
    glyph: Color(hex: 0x000000),
    backingFollowsMaterial: true)

  public static let dark = RimeKeyboardPalette(
    isDark: true,
    backing: Color(hex: 0x161616),
    keyCap: Color(hex: 0x3D3D3D),
    wideKeyCap: Color(hex: 0x444444),
    pressedKeyCap: Color(hex: 0x4E4E4E),
    pressedWideKeyCap: Color(hex: 0x363636),
    actionEnabled: Color(hex: 0x3378F4),
    actionDisabled: Color(hex: 0x737373),
    glyph: Color(hex: 0xFFFFFF),
    backingFollowsMaterial: true)

  public static func current(isDark: Bool) -> RimeKeyboardPalette {
    isDark ? .dark : .light
  }

  /// Which cap role a key has, which is the whole of S3 §4's rule as one decision: **is** the key wide
  /// (the view knows, because it drew the kind) and is it held. The *colour* then comes from
  /// `RimeKeyCapRole.colour(in:)`, so the measured appearance lives in exactly one place.
  public func capRole(isWide: Bool, isPressed: Bool) -> RimeKeyCapRole {
    if isPressed { return isWide ? .pressedWide : .pressedLetter }
    return isWide ? .wide : .letter
  }

  /// The cap role for a key: the return key is the action colour, everything else is wide or not by kind.
  public func capRole(for key: RimeKeyboardKey, isPressed: Bool, isEnabled: Bool = true) -> RimeKeyCapRole {
    if case .returnKey = key.kind {
      return isEnabled ? .actionEnabled : .actionDisabled
    }
    return capRole(isWide: key.kind.isWideCap, isPressed: isPressed)
  }

  /// The cap fill for a key, which is where "in light mode every key cap is white" lives.
  public func capFill(for key: RimeKeyboardKey, isPressed: Bool, isEnabled: Bool = true) -> Color {
    capRole(for: key, isPressed: isPressed, isEnabled: isEnabled).colour(in: self)
  }

  /// The action key's two measured states (S3 §6).
  public func returnKeyFill(isEnabled: Bool) -> Color {
    (isEnabled ? RimeKeyCapRole.actionEnabled : .actionDisabled).colour(in: self)
  }
}

// MARK: - Cap roles

/// What a key's cap is painted with. The view decides *which* role a key has — it is the one that knows the
/// kind it drew, whether a finger is on it and whether an action key is enabled — and the palette decides
/// what that role is painted with. Before this existed the keyboard had a second copy of the rule in its own
/// style-to-colour mapping, which no test on this machine could reach (see docs/s3-results.md).
public enum RimeKeyCapRole: String, Sendable, Hashable, CaseIterable {
  case letter
  case wide
  case pressedLetter
  case pressedWide
  case actionEnabled
  case actionDisabled
  /// A key with no cap at all, which is how the globe is drawn.
  case plain

  public func colour(in palette: RimeKeyboardPalette) -> RimeKeyboardPalette.Color {
    switch self {
    case .letter: return palette.keyCap
    case .wide: return palette.wideKeyCap
    case .pressedLetter: return palette.pressedKeyCap
    case .pressedWide: return palette.pressedWideKeyCap
    case .actionEnabled: return palette.actionEnabled
    case .actionDisabled: return palette.actionDisabled
    case .plain: return RimeKeyboardPalette.Color(red: 0, green: 0, blue: 0, alpha: 0)
    }
  }
}

// MARK: - Feedback

/// S3 §5's timings. The captures say nothing about timing, so these are the shipping consensus and
/// are calibrated on a device; keeping them here means the calibration changes one file.
public struct RimeKeyFeedback: Sendable, Equatable {
  public var deleteRepeatDelay: TimeInterval
  public var deleteRepeatInterval: TimeInterval
  /// A finger that slides further than this stops repeating rather than deleting something else.
  public var slideOffDistance: CGFloat
  public var calloutRadius: CGFloat
  /// The magnified cap's own height when there is room for it.
  public var calloutMinimumHeight: CGFloat
  /// How much wider than the key the callout is drawn.
  public var calloutWidthScale: CGFloat
  /// Phone-class devices only: an iPad's keyboard has no callout.
  public var calloutOnPhoneClassOnly: Bool
  public var calloutForModifierKeys: Bool
  public var calloutWhileRepeatingDelete: Bool

  public init(deleteRepeatDelay: TimeInterval = 0.5,
              deleteRepeatInterval: TimeInterval = 0.1,
              slideOffDistance: CGFloat = 50,
              calloutRadius: CGFloat = 10,
              calloutMinimumHeight: CGFloat = 64,
              calloutWidthScale: CGFloat = 1.6,
              calloutOnPhoneClassOnly: Bool = true,
              calloutForModifierKeys: Bool = false,
              calloutWhileRepeatingDelete: Bool = false) {
    self.deleteRepeatDelay = deleteRepeatDelay
    self.deleteRepeatInterval = deleteRepeatInterval
    self.slideOffDistance = slideOffDistance
    self.calloutRadius = calloutRadius
    self.calloutMinimumHeight = calloutMinimumHeight
    self.calloutWidthScale = calloutWidthScale
    self.calloutOnPhoneClassOnly = calloutOnPhoneClassOnly
    self.calloutForModifierKeys = calloutForModifierKeys
    self.calloutWhileRepeatingDelete = calloutWhileRepeatingDelete
  }

  public static let standard = RimeKeyFeedback()

  /// R10, as a number: the callout has to fit inside the keyboard, so the slot above the first key
  /// row is part of its budget.
  public func calloutSlotShortfall(candidateSlotHeight: CGFloat) -> CGFloat {
    max(0, calloutMinimumHeight - candidateSlotHeight)
  }
}

public enum RimeKeyFeedbackPolicy {
  /// Whether a key raises a magnified cap at all.
  public static func raisesCallout(_ key: RimeKeyboardKey,
                                   isPhoneClass: Bool = true,
                                   isRepeatingDelete: Bool = false,
                                   feedback: RimeKeyFeedback = .standard) -> Bool {
    if feedback.calloutOnPhoneClassOnly, !isPhoneClass { return false }
    if isRepeatingDelete, !feedback.calloutWhileRepeatingDelete { return false }
    switch key.kind {
    case .character, .space:
      return true
    case .shift, .delete, .layer, .emoji, .language, .returnKey, .globe:
      return feedback.calloutForModifierKeys
    }
  }

  /// The delay before the first repeat, and the interval after it.
  public static func deleteRepeatSchedule(feedback: RimeKeyFeedback = .standard)
    -> (delay: TimeInterval, interval: TimeInterval) {
    (feedback.deleteRepeatDelay, feedback.deleteRepeatInterval)
  }

  /// A slide cancels the repeat: the finger has left the key it started on.
  public static func cancelsDeleteRepeat(translation: CGSize,
                                         feedback: RimeKeyFeedback = .standard) -> Bool {
    abs(translation.width) > feedback.slideOffDistance
      || abs(translation.height) > feedback.slideOffDistance
  }
}

// MARK: - Callout geometry

/// The magnified cap's frame, clamped inside the keyboard's own bounds.
///
/// An extension cannot draw outside its frame, so this is not a nicety: a callout that escapes is
/// either clipped by the system or, worse, moves the keyboard's frame. R10's consequence is in
/// `availableHeight`: on the first letter row the room above the key is the candidate slot, 39.7 pt,
/// which is **less** than the callout's preferred height.
public enum RimeCalloutGeometry {
  public static func availableHeight(for key: RimeKeyboardKey, in bounds: CGRect) -> CGFloat {
    max(0, key.frame.minY - bounds.minY)
  }

  /// The frame the callout is drawn in: above the key where there is room, otherwise as tall as the
  /// room allows — never outside `bounds` or overlapping the key itself.
  ///
  /// `fingerX` makes it follow the finger across the grid (S3 §5): the callout is centred on the
  /// touch rather than on the key, and clamped the same way, so dragging towards an edge slides it to
  /// the edge instead of off the keyboard.
  public static func frame(for key: RimeKeyboardKey,
                           in bounds: CGRect,
                           fingerX: CGFloat? = nil,
                           feedback: RimeKeyFeedback = .standard) -> CGRect {
    let width = min(key.frame.width * feedback.calloutWidthScale, bounds.width)
    let centre = (fingerX ?? key.frame.midX) - bounds.minX
    let x = min(max(centre - width / 2, bounds.minX), bounds.maxX - width)
    let available = availableHeight(for: key, in: bounds)
    let height = min(feedback.calloutMinimumHeight, max(available, 0))
    return CGRect(x: x, y: key.frame.minY - height, width: width, height: height)
  }

  /// The row pitch a full-height callout needs above the first key row, which is what the keyboard's
  /// height budget has to reserve (R10).
  public static func requiredTopSlot(feedback: RimeKeyFeedback = .standard) -> CGFloat {
    feedback.calloutMinimumHeight
  }
}

// MARK: - Shift

/// S3 §5's shift behaviour: one-shot after a tap, caps lock after a double tap, consumed by the next
/// character.
public struct RimeShiftController: Sendable {
  public private(set) var state: RimeShiftState
  private var lastTap: Date?
  public var doubleTapInterval: TimeInterval

  public init(state: RimeShiftState = .off, doubleTapInterval: TimeInterval = 0.3) {
    self.state = state
    self.doubleTapInterval = doubleTapInterval
  }

  @discardableResult
  public mutating func tap(at time: Date = Date()) -> RimeShiftState {
    defer { lastTap = time }
    // The delta must be positive as well as small: a clock that goes backwards (or a caller that
    // replays events) must not read as a double tap.
    if let last = lastTap {
      let delta = time.timeIntervalSince(last)
      if delta >= 0, delta <= doubleTapInterval {
        state = state.doubleTapped()
        return state
      }
    }
    state = state.tapped()
    return state
  }

  /// A character key was pressed: a one-shot shift is spent, caps stays until it is tapped again.
  @discardableResult
  public mutating func consumeAfterCharacter() -> RimeShiftState {
    if state == .on { state = .off }
    return state
  }

  public mutating func reset() {
    state = .off
    lastTap = nil
  }

  /// True while the shift key should show its filled state.
  public var isActive: Bool { state != .off }
}
public extension RimeKeyboardKey.Kind {
  /// Whether the cap is a wide one — the one input to S3 §4's rule that only a view can supply, because a view
  /// is what decided which kind of key to draw. The rule itself stays here, so the space bar and the return
  /// key cannot be painted by two different answers.
  var isWideCap: Bool {
    switch self {
    case .character: return false
    case .shift, .delete, .layer, .emoji, .language, .space, .returnKey, .globe: return true
    }
  }
}
