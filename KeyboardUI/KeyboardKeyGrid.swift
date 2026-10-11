import UIKit
import RimeEngine

enum KeyboardKey: Hashable {
  case character(String)
  case auxiliary(String)
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

enum KeyboardKeyLabels {
  static var systemLanguage: String { RimeLocalization.language.rawValue }

  static func space(language: String) -> String {
    RimeLocalization.text("Space", language: language.lowercased().hasPrefix("zh") ? .chinese : .english)
  }

  static func returnKey(_ type: UIReturnKeyType, language: String) -> String {
    let selected: RimeAppLanguage = language.lowercased().hasPrefix("zh") ? .chinese : .english
    switch type {
    case .send: return RimeLocalization.text("Send", language: selected)
    case .search, .google, .yahoo: return RimeLocalization.text("Search", language: selected)
    case .go: return RimeLocalization.text("Go", language: selected)
    case .done: return RimeLocalization.text("Done", language: selected)
    case .next: return RimeLocalization.text("Next", language: selected)
    case .continue: return RimeLocalization.text("Continue", language: selected)
    case .join: return RimeLocalization.text("Join", language: selected)
    case .route: return RimeLocalization.text("Route", language: selected)
    case .emergencyCall: return RimeLocalization.text("Emergency call", language: selected)
    default: return RimeLocalization.text("Return", language: selected)
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
  private var chineseInputOnly = false
  private var shift: RimeShiftState = .off
  private var language: RimeLanguageKey?
  private var returnKeyLabel = RimeLocalization.text("Return")
  private var spaceKeyLabel = RimeLocalization.text("Space")
  private var showsGlobeRow = false
  private var feedback = RimeKeyFeedback.standard
  private var auxiliaryPrefix = ","
  private var leftSpaceKey = RimeSpaceSideKey()
  private var rightSpaceKey = RimeSpaceSideKey()

  /// Last configuration actually applied. Restyling the whole grid on every keystroke (fonts,
  /// SF Symbol lookups, colours) was a measurable part of the input latency.
  private var applied: (keyLayer: KeyLayer, shift: RimeShiftState, asciiMode: Bool,
                        returnKeyLabel: String, spaceKeyLabel: String, showsGlobeRow: Bool,
                        appearance: UIKeyboardAppearance, language: RimeLanguageKey?,
                        auxiliaryPrefix: String, leftSpaceKey: RimeSpaceSideKey, rightSpaceKey: RimeSpaceSideKey, chineseInputOnly: Bool)?
  private var laidOutWidth: CGFloat = 0

  /// The style the grid lays its rows out with: the candidate slot and the bottom inset belong to
  /// the views that own them, so this grid's coordinate space starts at its first row.
  private static func rowStyle(width: CGFloat) -> RimeKeyboardStyle {
    var style = KeyboardMetrics.style
    style.candidateSlotHeight = 0
    style.bottomInset = 0
    // The bottom row's outer keys keep their widths; space absorbs the device
    // width so return stays inside the host on phones narrower than 430 pt.
    style.spaceKeyWidth = max(1, width - 2 * style.sideMargin - 3 * style.horizontalGap
      - style.layerKeyWidth - style.emojiKeyWidth - style.returnKeyWidth)
    return style
  }

  static func rowsHeight(width: CGFloat, needsGlobeRow: Bool) -> CGFloat {
    RimeKeyboardLayoutEngine.layout(width: max(width, 1), layer: .letters,
                                    needsGlobeRow: needsGlobeRow, style: rowStyle(width: max(width, 1))).height
  }

  func configure(theme: KeyboardTheme,
                 layer: KeyLayer,
                 asciiMode: Bool,
                 returnKeyLabel: String,
                 spaceKeyLabel: String = KeyboardKeyLabels.space(language: KeyboardKeyLabels.systemLanguage),
                 showsGlobeRow: Bool,
                 shift: RimeShiftState = .off,
                 language: RimeLanguageKey? = nil,
                 feedback: RimeKeyFeedback = .standard,
                 auxiliaryPrefix: String = ",",
                 leftSpaceKey: RimeSpaceSideKey = RimeSpaceSideKey(),
                 rightSpaceKey: RimeSpaceSideKey = RimeSpaceSideKey(),
                 chineseInputOnly: Bool = false) {
    if self.feedback != feedback {
      self.feedback = feedback
      for entry in buttons { entry.view.feedback = feedback }
    }
    // The 中/英 label is part of the *key*, not a style applied to it, so a label that changes on its own
    // needs new keys rather than a restyle — and it is the one applied field the comparison below did not
    // look at, which kept the old word on the cap (found by KeyboardLayerTests, round 148).
    let previousChineseInputOnly = applied?.chineseInputOnly
    let previousLanguage = applied?.language
    let previousShift = applied?.shift
    let previousLayer = applied?.keyLayer
    let previousAuxiliaryPrefix = applied?.auxiliaryPrefix
    let previousLeftSpaceKey = applied?.leftSpaceKey
    let previousRightSpaceKey = applied?.rightSpaceKey
    if let applied,
       applied.chineseInputOnly == chineseInputOnly,
       applied.keyLayer == layer,
       applied.shift == shift,
       applied.asciiMode == asciiMode,
       applied.returnKeyLabel == returnKeyLabel,
       applied.spaceKeyLabel == spaceKeyLabel,
       applied.showsGlobeRow == showsGlobeRow,
       applied.appearance == theme.appearance,
       applied.language == language,
       applied.auxiliaryPrefix == auxiliaryPrefix,
       applied.leftSpaceKey == leftSpaceKey,
       applied.rightSpaceKey == rightSpaceKey {
      return
    }
    applied = (layer, shift, asciiMode, returnKeyLabel, spaceKeyLabel, showsGlobeRow, theme.appearance, language, auxiliaryPrefix, leftSpaceKey, rightSpaceKey, chineseInputOnly)

    self.theme = theme
    self.currentLayer = layer
    self.asciiMode = asciiMode
    self.chineseInputOnly = chineseInputOnly
    self.shift = shift
    self.returnKeyLabel = returnKeyLabel
    self.spaceKeyLabel = spaceKeyLabel
    self.showsGlobeRow = showsGlobeRow
    self.language = language
    self.feedback = feedback
    self.auxiliaryPrefix = auxiliaryPrefix
    self.leftSpaceKey = leftSpaceKey
    self.rightSpaceKey = rightSpaceKey

    // Shift changes both the cap and the key value. Update the existing controls in place so a
    // one-shot Shift press does not destroy and recreate the whole keyboard twice.
    let layout = currentLayout(width: max(laidOutWidth, 1))
    let onlyShiftChanged = previousShift != shift
      && previousChineseInputOnly == chineseInputOnly
      && previousLayer == layer
      && previousLanguage == language
      && previousAuxiliaryPrefix == auxiliaryPrefix
      && previousLeftSpaceKey == leftSpaceKey
      && previousRightSpaceKey == rightSpaceKey
      && buttons.count == layout.keys.count
    let needsRebuild = buttons.isEmpty
      || buttons.count != layout.keys.count
      || previousChineseInputOnly != chineseInputOnly
      || previousLayer != layer
      || previousLanguage != language
      || previousAuxiliaryPrefix != auxiliaryPrefix
      || previousLeftSpaceKey != leftSpaceKey
      || previousRightSpaceKey != rightSpaceKey
    if onlyShiftChanged {
      updateKeys(in: layout)
    } else if needsRebuild {
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
      shift: shift,
      returnKey: RimeReturnKey(label: returnKeyLabel),
      language: language,
      needsGlobeRow: showsGlobeRow,
      style: Self.rowStyle(width: width),
      auxiliaryPrefix: auxiliaryPrefix, leftSpaceKey: leftSpaceKey, rightSpaceKey: rightSpaceKey,
      chineseInputOnly: chineseInputOnly)
  }

  private func rebuild() {
    for entry in buttons {
      entry.view.removeFromSuperview()
    }
    buttons.removeAll()

    let layout = currentLayout(width: max(laidOutWidth, 1))
    for key in layout.keys {
      let button = KeyButton(frame: .zero)
      configure(button, for: key)
      if button.key != nil {
        button.addTarget(self, action: #selector(handleKeyPress(_:)), for: .primaryActionTriggered)
        button.isAccessibilityElement = true
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
    }
    refreshAppearance()
  }

  private func updateKeys(in layout: RimeKeyboardLayout) {
    for (index, key) in layout.keys.enumerated() {
      let button = buttons[index].view
      configure(button, for: key)
      if let mapped = button.key { buttons[index] = (mapped, button) }
    }
    refreshAppearance()
  }

  private func configure(_ button: KeyButton, for key: RimeKeyboardKey) {
    button.key = self.key(for: key)
    button.repeatsWhileHeld = button.key == .backspace
    button.feedback = feedback
    button.accessibilityLabel = key.accessibilityLabel
    // The model's frame positions the callout. Convert button-local touch points into grid space.
    button.onTouchDown = { [weak self, weak button] point in
      guard let self, let button else { return }
      self.onKeyTouchDown?(key, button.convert(point, to: self))
    }
    button.onTouchMove = { [weak self, weak button] point in
      guard let self, let button else { return }
      self.onKeyTouchMove?(key, button.convert(point, to: self))
    }
    button.onTouchEnded = { [weak self] in self?.onKeyTouchEnded?() }
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
    case .character(let text):
      return key.isAuxiliary ? .auxiliary(text) : .character(text)
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
  /// A plain return has the native arrow and a wide cap. Named actions retain their blue action cap.
  private func role(for key: KeyboardKey) -> RimeKeyCapRole {
    switch key {
    case .character, .auxiliary: return .letter
    case .space: return .wide
    case .shift: return shift != .off ? .pressedLetter : .wide
    case .returnKey: return usesReturnSymbol ? .wide : .actionEnabled
    case .globe: return .plain
    default: return .wide
    }
  }

  private func style(for key: KeyboardKey) -> KeyButton.Style {
    switch key {
    case .character, .auxiliary, .space:
      return .letter
    case .shift:
      return shift != .off ? .active : .special
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
    case .character(let value), .auxiliary(let value):
      // The layout supplies the exact character sent on tap, including shifted letters.
      button.setTitle(value, pointSize: 25, verticalOffset: -2)
    case .space:
      button.setTitle(currentLayer == .numbers ? "" : spaceKeyLabel, pointSize: 16)
    case .returnKey:
      if usesReturnSymbol {
        button.setSymbol("return", pointSize: 22)
      } else if returnKeyLabel == RimeLocalization.text("Search") || returnKeyLabel == "Search" {
        button.setSymbol("magnifyingglass", pointSize: 22)
      } else {
        button.setTitle(returnKeyLabel, pointSize: 16)
      }
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

  private var usesReturnSymbol: Bool {
    returnKeyLabel == RimeLocalization.text("Return") || returnKeyLabel.lowercased() == "return"
  }
}
