import UIKit
import RimeEngine

enum KeyboardKey: Hashable {
  case character(String)
  case shift
  case backspace
  case space
  case returnKey
  case numbers
  case symbols
  case letters
  case emoji
  /// S3 §5's 中/英 key, whose label is the state the user is in.
  case language(String)
  case globe
}

enum KeyLayer {
  case letters
  case numbers
  case symbols

  var rimeLayer: RimeKeyboardLayer {
    switch self {
    case .letters: return .letters
    case .numbers: return .numbers
    case .symbols: return .symbols
    }
  }
}

/// Key rows share the same style and geometry engine as the extension height.
final class KeyboardKeyGrid: UIView {
  var onKey: ((KeyboardKey) -> Void)?
  /// The touch's life on a key, in the grid's own coordinates, so the caller owns the callout: it has
  /// to be positioned against the whole keyboard, not against the grid — the callout draws into the
  /// candidate slot above the first row.
  var onKeyTouchDown: ((RimeKeyboardKey, CGPoint) -> Void)?
  var onKeyTouchMove: ((RimeKeyboardKey, CGPoint) -> Void)?
  var onKeyTouchEnded: (() -> Void)?

  private var buttons: [(key: KeyboardKey, view: KeyButton)] = []
  private var theme = KeyboardTheme.current(for: .default)
  private var currentLayer: KeyLayer = .letters
  private var asciiMode = false
  private var shift: RimeShiftState = .off
  private var language: RimeLanguageKey?
  private var returnKeyLabel = "换行"
  private var showsGlobeRow = false
  private var feedback = RimeKeyFeedback.standard

  /// Last configuration actually applied. Restyling the whole grid on every keystroke (fonts,
  /// SF Symbol lookups, colours) was a measurable part of the input latency.
  private var applied: (keyLayer: KeyLayer, shift: RimeShiftState, asciiMode: Bool,
                        returnKeyLabel: String, showsGlobeRow: Bool,
                        appearance: UIKeyboardAppearance, language: RimeLanguageKey?)?
  private var laidOutWidth: CGFloat = 0

  /// The style the grid lays its rows out with: the candidate slot and the bottom inset belong to
  /// the views that own them, so this grid's coordinate space starts at its first row.
  private static var rowStyle: RimeKeyboardStyle {
    var style = KeyboardMetrics.style
    style.candidateSlotHeight = 0
    style.bottomInset = 0
    return style
  }

  static func rowsHeight(width: CGFloat, needsGlobeRow: Bool) -> CGFloat {
    RimeKeyboardLayoutEngine.layout(width: max(width, 1), layer: .letters,
                                    needsGlobeRow: needsGlobeRow, style: rowStyle).height
  }

  func configure(theme: KeyboardTheme,
                 layer: KeyLayer,
                 asciiMode: Bool,
                 returnKeyLabel: String,
                 showsGlobeRow: Bool,
                 shift: RimeShiftState = .off,
                 language: RimeLanguageKey? = nil,
                 feedback: RimeKeyFeedback = .standard) {
    // The 中/英 label is part of the *key*, not a style applied to it, so a label that changes on its own
    // needs new keys rather than a restyle — and it is the one applied field the comparison below did not
    // look at, which kept the old word on the cap (found by KeyboardLayerTests, round 148).
    let previousLanguage = applied?.language
    let previousShift = applied?.shift
    if let applied,
       applied.keyLayer == layer,
       applied.shift == shift,
       applied.asciiMode == asciiMode,
       applied.returnKeyLabel == returnKeyLabel,
       applied.showsGlobeRow == showsGlobeRow,
       applied.appearance == theme.appearance,
       applied.language == language {
      return
    }
    applied = (layer, shift, asciiMode, returnKeyLabel, showsGlobeRow, theme.appearance, language)

    self.theme = theme
    self.currentLayer = layer
    self.asciiMode = asciiMode
    self.shift = shift
    self.returnKeyLabel = returnKeyLabel
    self.showsGlobeRow = showsGlobeRow
    self.language = language
    self.feedback = feedback

    // A different key set has to be rebuilt; a different colour does not.
    // A shift change rebuilds rather than restyles: the label a character key reports is the layout's, and
    // the layout's is cased. Restyling could only paint the old case over the new state — and the key would
    // still *type* the old one — which is how shift-off left the board in capitals (found by
    // KeyboardLayerTests, round 148).
    let needsRebuild = buttons.isEmpty
      || buttons.count != currentLayout(width: max(laidOutWidth, 1)).keys.count
      || previousLanguage != language
      || previousShift != shift
    if needsRebuild {
      rebuild()
    } else {
      refreshAppearance()
    }
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  override var intrinsicContentSize: CGSize {
    let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
    return CGSize(width: UIView.noIntrinsicMetric,
                  height: Self.rowsHeight(width: width, needsGlobeRow: showsGlobeRow))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0 else { return }
    if abs(bounds.width - laidOutWidth) > 0.5 {
      laidOutWidth = bounds.width
      rebuild()
      invalidateIntrinsicContentSize()
    }
    // Placing the keys is this pass's job. The first version returned here after a rebuild, so every key
    // kept its zero frame until some later layout pass — invisible on a device, where UIKit schedules one
    // anyway, and a blank keyboard wherever it does not. The iOS test target's first run on a simulator
    // found it: 191 assertions, every key 0 x 0 (round 141).
    placeButtons()
  }

  // MARK: - The model's keys

  private func currentLayout(width: CGFloat) -> RimeKeyboardLayout {
    RimeKeyboardLayoutEngine.layout(
      width: width,
      layer: currentLayer.rimeLayer,
      shift: shift.isUppercase ? shift : (asciiMode ? .on : .off),
      returnKey: RimeReturnKey(label: returnKeyLabel),
      language: language,
      needsGlobeRow: showsGlobeRow,
      style: Self.rowStyle)
  }

  private func rebuild() {
    for entry in buttons {
      entry.view.removeFromSuperview()
    }
    buttons.removeAll()

    let layout = currentLayout(width: max(laidOutWidth, 1))
    for key in layout.keys {
      let button = KeyButton(frame: .zero)
      button.key = self.key(for: key)
      if let mapped = button.key {
        button.repeatsWhileHeld = (mapped == .backspace)
        button.feedback = feedback
        button.addTarget(self, action: #selector(handleKeyPress(_:)), for: .primaryActionTriggered)
        button.isAccessibilityElement = true
        button.accessibilityLabel = key.accessibilityLabel
        // The accessibility label is the character or the action; the trait tells VoiceOver it is a
        // key rather than a paragraph (S3 §8).
        button.accessibilityTraits = .keyboardKey
      } else {
        button.isUserInteractionEnabled = false
      }
      addSubview(button)
      if let mapped = button.key {
        buttons.append((mapped, button))
      }
      // The model's key carries the frame the callout is positioned from; the app's key does not.
      // The point arrives in the button's own coordinates and is documented to leave in the grid's: the
      // caller positions the callout against the whole keyboard, so a button-local point puts it a key to
      // the left. The button is a direct subview, so this is the whole conversion. (Found by
      // KeyboardCalloutTests: the callout sat at x=20 for a key at x=215.)
      button.onTouchDown = { [weak self, weak button] point in
        guard let self, let button else { return }
        self.onKeyTouchDown?(key, button.convert(point, to: self))
      }
      button.onTouchMove = { [weak self, weak button] point in
        guard let self, let button else { return }
        self.onKeyTouchMove?(key, button.convert(point, to: self))
      }
      button.onTouchEnded = { [weak self] in
        self?.onKeyTouchEnded?()
      }
    }
    refreshAppearance()
  }

  private func placeButtons() {
    let layout = currentLayout(width: bounds.width)
    guard layout.keys.count == buttons.count else {
      rebuild()
      return
    }
    for (index, key) in layout.keys.enumerated() {
      buttons[index].view.frame = key.frame
    }
  }

  /// The app's key vocabulary from the model's. `nil` would be a key the controller cannot act on,
  /// and there are none: every kind the engine emits is handled.
  private func key(for key: RimeKeyboardKey) -> KeyboardKey? {
    switch key.kind {
    case .character(let text): return .character(text)
    case .shift: return .shift
    case .delete: return .backspace
    case .space: return .space
    case .returnKey: return .returnKey
    case .emoji: return .emoji
    case .language(let value): return .language(value.label)
    case .globe: return .globe
    case .layer(let target):
      switch target {
      case .letters: return .letters
      case .numbers: return .numbers
      case .symbols: return .symbols
      }
    }
  }

  @objc private func handleKeyPress(_ sender: KeyButton) {
    guard let key = sender.key else { return }
    onKey?(key)
  }

  // MARK: - Appearance

  private func refreshAppearance() {
    for entry in buttons {
      entry.view.apply(theme: theme, style: style(for: entry.key), role: role(for: entry.key))
      applyContent(for: entry.key, to: entry.view)
    }
  }

  /// Which cap role this key has. The *rule* is the engine's (S3 §4: wide keys are lighter in dark mode, a
  /// key with no cap has none); this is only the translation from the keyboard's own vocabulary, which is the
  /// one thing a view knows and the model cannot.
  ///
  /// Two divergences were found here and are fixed: the space bar is a **wide** cap (it used to take the
  /// letter colour, which is a different colour in dark mode), and the return key is the **action** colour
  /// (it used to take the wide cap, so the measured blue was never painted). The keyboard never learns that
  /// the return key is disabled — UIKit does not say — so the enabled colour is what it paints.
  private func role(for key: KeyboardKey) -> RimeKeyCapRole {
    switch key {
    case .character: return .letter
    case .space: return .wide
    case .shift: return shift != .off || asciiMode ? .pressedLetter : .wide
    case .returnKey: return .actionEnabled
    case .globe: return .plain
    default: return .wide
    }
  }

  private func style(for key: KeyboardKey) -> KeyButton.Style {
    switch key {
    case .character, .space:
      return .letter
    case .shift:
      return shift != .off || asciiMode ? .active : .special
    case .language:
      return .special
    case .globe:
      return .plain
    default:
      return .special
    }
  }

  private func applyContent(for key: KeyboardKey, to button: KeyButton) {
    switch key {
    case .character(let value):
      let uppercase = !value.isEmpty
        && value.rangeOfCharacter(from: .letters) != nil
        && (shift.isUppercase || asciiMode)
      button.setTitle(uppercase ? value.uppercased() : value, pointSize: 24)
    case .space:
      button.setTitle("空格", pointSize: 16)
    case .returnKey:
      button.setTitle(returnKeyLabel, pointSize: 16)
    case .numbers:
      button.setTitle("123", pointSize: 16)
    case .symbols:
      button.setTitle("#+=", pointSize: 16)
    case .letters:
      button.setTitle("ABC", pointSize: 16)
    case .shift:
      button.setSymbol(shift == .caps ? "capslock.fill" : (shift != .off ? "shift.fill" : "shift"),
                       pointSize: 20)
    case .backspace:
      button.setSymbol("delete.left", pointSize: 20)
    case .emoji:
      button.setSymbol("face.smiling", pointSize: 20)
    case .language(let label):
      button.setTitle(label, pointSize: 16)
    case .globe:
      button.setSymbol("globe", pointSize: 20)
    }
  }
}
