import CoreGraphics
import Foundation

// MARK: - Style

/// S3 §2.1: every metric lives here, with its provenance, and no view file carries a magic number.
///
/// Measured on an iPhone 15 Pro Max (430 × 932 pt, 3×) running iOS 26, from five reference captures
/// — letters light, letters dark, numbers, symbols, and the expanded candidate panel. Geometry is
/// identical in light and dark.
public struct RimeKeyboardStyle: Sendable, Equatable {
  public var sideMargin: CGFloat
  public var horizontalGap: CGFloat
  public var rowGap: CGFloat
  public var keyHeight: CGFloat
  public var candidateSlotHeight: CGFloat
  /// Everything below the last key row, including the 34 pt home-indicator safe area.
  public var bottomInset: CGFloat
  /// Half a slot: the second letter row is indented by this.
  public var secondRowIndent: CGFloat
  public var shiftWidth: CGFloat
  public var deleteWidth: CGFloat
  /// The gap between shift/delete and the letter block — wider than the key gap.
  public var sideKeyGap: CGFloat
  /// Bottom row widths: 123 / emoji / space region / return.
  /// The space region also accommodates the comma and optional auxiliary key.
  public var layerKeyWidth: CGFloat
  public var emojiKeyWidth: CGFloat
  public var spaceKeyWidth: CGFloat
  public var returnKeyWidth: CGFloat
  public var cornerRadius: CGFloat
  public var globeRowHeight: CGFloat

  public init(sideMargin: CGFloat, horizontalGap: CGFloat, rowGap: CGFloat, keyHeight: CGFloat,
              candidateSlotHeight: CGFloat, bottomInset: CGFloat, secondRowIndent: CGFloat,
              shiftWidth: CGFloat, deleteWidth: CGFloat, sideKeyGap: CGFloat,
              layerKeyWidth: CGFloat, emojiKeyWidth: CGFloat, spaceKeyWidth: CGFloat,
              returnKeyWidth: CGFloat, cornerRadius: CGFloat, globeRowHeight: CGFloat) {
    self.sideMargin = sideMargin
    self.horizontalGap = horizontalGap
    self.rowGap = rowGap
    self.keyHeight = keyHeight
    self.candidateSlotHeight = candidateSlotHeight
    self.bottomInset = bottomInset
    self.secondRowIndent = secondRowIndent
    self.shiftWidth = shiftWidth
    self.deleteWidth = deleteWidth
    self.sideKeyGap = sideKeyGap
    self.layerKeyWidth = layerKeyWidth
    self.emojiKeyWidth = emojiKeyWidth
    self.spaceKeyWidth = spaceKeyWidth
    self.returnKeyWidth = returnKeyWidth
    self.cornerRadius = cornerRadius
    self.globeRowHeight = globeRowHeight
  }

  /// The measured reference (S3 §3).
  public static let measured = RimeKeyboardStyle(
    sideMargin: 8.3,
    horizontalGap: 9.7,
    rowGap: 11.0,
    keyHeight: 45.0,
    candidateSlotHeight: 39.7,
    bottomInset: 80.3,
    secondRowIndent: 21.05,
    shiftWidth: 45.1,
    deleteWidth: 45.4,
    sideKeyGap: 18.4,
    layerKeyWidth: 43.4,
    emojiKeyWidth: 43.1,
    spaceKeyWidth: 201.4,
    returnKeyWidth: 96.4,
    cornerRadius: 6.7,
    globeRowHeight: 40.0)

  /// Revised from the October 2026 side-by-side reference. Keep `measured` as the
  /// historical capture baseline; the UI uses this wider, flat-cap treatment.
  public static let systemAligned: RimeKeyboardStyle = {
    var style = measured
    // The reference candidate strip includes the breathing room above the first key row.
    style.candidateSlotHeight = 52
    style.sideMargin = 6.5
    style.horizontalGap = 6
    style.cornerRadius = 8.5
    style.shiftWidth = 48.5
    style.deleteWidth = 48.5
    style.sideKeyGap = 15
    style.layerKeyWidth = 46.5
    style.emojiKeyWidth = 47
    // Give the comma and auxiliary keys room without squeezing the space bar.
    style.spaceKeyWidth = 240.5
    style.returnKeyWidth = 64
    return style
  }()

  /// The letter key width at a given keyboard width: `keyWidth = (width − 2 × margin − 9 × gap) / 10`
  /// (S3 §3.1). At 430 pt this is 32.6 pt, which is the measurement.
  public func letterKeyWidth(for width: CGFloat) -> CGFloat {
    (width - 2 * sideMargin - 9 * horizontalGap) / 10
  }

  public func slotPitch(for width: CGFloat) -> CGFloat {
    letterKeyWidth(for: width) + horizontalGap
  }
}

// MARK: - State

public enum RimeKeyboardLayer: String, Sendable, Hashable, CaseIterable {
  case letters
  case numbers
  case symbols

  public var switchLabel: String {
    switch self {
    case .letters: return "ABC"
    case .numbers: return "123"
    case .symbols: return "#+="
    }
  }

  /// What VoiceOver says for the key that switches to this layer (S3 §8).
  public var accessibilityLabel: String {
    switch self {
    case .letters: return RimeLocalization.text("Letters")
    case .numbers: return RimeLocalization.text("Numbers")
    case .symbols: return RimeLocalization.text("Symbols")
    }
  }
}

public enum RimeShiftState: String, Sendable, Hashable, CaseIterable {
  case off
  case on
  case caps

  public var isUppercase: Bool { self != .off }

  /// The next state after a tap, and after a double tap (S3 §5).
  public func tapped() -> RimeShiftState { self == .off ? .on : .off }
  public func doubleTapped() -> RimeShiftState { .caps }
}

/// The action key's two visible states (S3 §6).
public struct RimeReturnKey: Sendable, Hashable {
  public var label: String
  public var isEnabled: Bool

  public init(label: String = RimeLocalization.text("Return"), isEnabled: Bool = true) {
    self.label = label
    self.isEnabled = isEnabled
  }

  public enum Kind: String, Sendable, CaseIterable {
    case newline, search, send, go, done, join, next, route, continueKey, emergencyCall

    public var label: String {
      switch self {
      case .newline: return RimeLocalization.text("Return")
      case .search: return RimeLocalization.text("Search")
      case .send: return RimeLocalization.text("Send")
      case .go: return RimeLocalization.text("Go")
      case .done: return RimeLocalization.text("Done")
      case .join: return RimeLocalization.text("Join")
      case .next: return RimeLocalization.text("Next")
      case .route: return RimeLocalization.text("Route")
      case .continueKey: return RimeLocalization.text("Continue")
      case .emergencyCall: return RimeLocalization.text("Emergency call")
      }
    }
  }
}

// MARK: - Keys and rows

public struct RimeKeyboardKey: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case character(String)
    case shift(RimeShiftState)
    case delete
    case layer(RimeKeyboardLayer)
    /// The emoji key. Kept as a kind because a schema-less fallback row still has the slot, but the
    /// bottom row emits it only when there is no language key to put there instead.
    case emoji
    /// The 中/英 key, whose label and state come from the schema.
    case language(RimeLanguageKey)
    case space
    case returnKey
    case globe
  }

  public let kind: Kind
  /// The frame inside the keyboard's own coordinate space, origin at the top-left.
  public let frame: CGRect
  public let label: String
  /// What VoiceOver says (S3 §8): the character, or the action in the keyboard's language.
  public let accessibilityLabel: String
  public let isAuxiliary: Bool
  /// Whether the key belongs to the main character rows rather than the bottom controls.
  public let isCore: Bool

  public init(kind: Kind, frame: CGRect, label: String, accessibilityLabel: String, isAuxiliary: Bool = false, isCore: Bool = true) {
    self.kind = kind
    self.frame = frame
    self.label = label
    self.accessibilityLabel = accessibilityLabel
    self.isAuxiliary = isAuxiliary
    self.isCore = isCore
  }

  /// The same key at another frame, which is how a row places its keys.
  init(kind: Kind, label: String, accessibilityLabel: String, frame: CGRect, isAuxiliary: Bool = false, isCore: Bool = true) {
    self.init(kind: kind, frame: frame, label: label, accessibilityLabel: accessibilityLabel, isAuxiliary: isAuxiliary, isCore: isCore)
  }

  public var isCharacter: Bool {
    if case .character = kind { return true }
    return false
  }
}

public struct RimeKeyboardRow: Sendable {
  public let frame: CGRect
  public let keys: [RimeKeyboardKey]

  public init(frame: CGRect, keys: [RimeKeyboardKey]) {
    self.frame = frame
    self.keys = keys
  }
}

/// One rendered state of the keyboard: the rows, the candidate slot, and the height the extension
/// must ask for.
public struct RimeKeyboardLayout: Sendable {
  public let size: CGSize
  public let candidateSlot: CGRect
  public let rows: [RimeKeyboardRow]
  public let layer: RimeKeyboardLayer
  public let shift: RimeShiftState
  public let returnKey: RimeReturnKey
  public let needsGlobeRow: Bool

  public var keys: [RimeKeyboardKey] { rows.flatMap(\.keys) }
  public var height: CGFloat { size.height }
}

// MARK: - Engine

/// S3 §3.1's layout model: fixed margins and gaps, key widths that flex with the keyboard's width,
/// and a total height that is the sum of its parts rather than a guess.
public enum RimeKeyboardLayoutEngine {
  public static func layout(width: CGFloat,
                            layer: RimeKeyboardLayer = .letters,
                            shift: RimeShiftState = .off,
                            returnKey: RimeReturnKey = RimeReturnKey(),
                            language: RimeLanguageKey? = nil,
                            needsGlobeRow: Bool = false,
                            style: RimeKeyboardStyle = .measured,
                            auxiliaryPrefix: String? = nil,
                            leftSpaceKey: RimeSpaceSideKey = RimeSpaceSideKey(),
                            rightSpaceKey: RimeSpaceSideKey = RimeSpaceSideKey(),
                            chineseInputOnly: Bool = false,
                            punctuationLabels: [String: String] = [:]) -> RimeKeyboardLayout {
    var y = style.candidateSlotHeight
    var rows: [RimeKeyboardRow] = []

    switch layer {
    case .letters:
      rows.append(row(y: y, style: style, keys: letterRow1(width: width, shift: shift, style: style)))
      y += style.keyHeight + style.rowGap
      rows.append(row(y: y, style: style, keys: letterRow2(width: width, shift: shift, style: style)))
      y += style.keyHeight + style.rowGap
      rows.append(row(y: y, style: style, keys: letterRow3(width: width, shift: shift, style: style)))
      y += style.keyHeight + style.rowGap
      rows.append(row(y: y, style: style, keys: bottomRow(width: width, layer: .numbers,
                                                          style: style, returnKey: returnKey,
                                                          language: language, auxiliaryPrefix: auxiliaryPrefix,
                                                          leftSpaceKey: leftSpaceKey, rightSpaceKey: rightSpaceKey,
                                                          chineseInputOnly: chineseInputOnly)))
    case .numbers, .symbols:
      let first = layer == .numbers
        ? ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        : ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
      rows.append(row(y: y, style: style, keys: plainRow(first, width: width, style: style)))
      y += style.keyHeight + style.rowGap
      let second = layer == .numbers
        ? ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
        : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
      rows.append(row(y: y, style: style, keys: plainRow(second, width: width, style: style)))
      y += style.keyHeight + style.rowGap
      let third = layer == .numbers
        ? [".", ",", "?", "!", "'"]
        : ["%", "‰", "√", "π", "≈"]
      // The switch key on this row goes to the *other* punctuation layer, not to the letters: S3 §3.2
      // gives the numbers layer a `#+=` key and the symbols layer a `123` key.
      let thirdSwitch: RimeKeyboardLayer = layer == .numbers ? .symbols : .numbers
      rows.append(row(y: y, style: style,
                      keys: specialThirdRow(third, width: width, layer: thirdSwitch, style: style,
                                            outerGap: layer == .numbers ? style.sideKeyGap : nil)))
      y += style.keyHeight + style.rowGap
      rows.append(row(y: y, style: style, keys: bottomRow(width: width, layer: .letters,
                                                          style: style, returnKey: returnKey,
                                                          language: language, auxiliaryPrefix: auxiliaryPrefix,
                                                          leftSpaceKey: leftSpaceKey, rightSpaceKey: rightSpaceKey,
                                                          chineseInputOnly: chineseInputOnly)))
    }

    y += style.keyHeight
    if needsGlobeRow {
      y += style.rowGap
      rows.append(row(y: y, style: style, keys: globeRow(width: width, style: style)))
      y += style.globeRowHeight
    }
    let height = y + style.bottomInset
    rows = rows.enumerated().map { rowIndex, row in
      RimeKeyboardRow(frame: row.frame, keys: row.keys.map { key in
        let label: String
        if case .character(let input) = key.kind, !key.isAuxiliary {
          label = punctuationLabels[input] ?? key.label
        } else {
          label = key.label
        }
        return RimeKeyboardKey(kind: key.kind, frame: key.frame, label: label,
                               accessibilityLabel: label == key.label ? key.accessibilityLabel : label,
                               isAuxiliary: key.isAuxiliary, isCore: rowIndex < 3)
      })
    }

    return RimeKeyboardLayout(size: CGSize(width: width, height: height),
                              candidateSlot: CGRect(x: 0, y: 0, width: width,
                                                    height: style.candidateSlotHeight),
                              rows: rows, layer: layer, shift: shift, returnKey: returnKey,
                              needsGlobeRow: needsGlobeRow)
  }

  // MARK: Rows

  /// Places a row at `y` and gives every key an **absolute** frame in the keyboard's own coordinate
  /// space. Row-local frames would make each key unusable on its own, and the callout is positioned
  /// from the key it belongs to: it needs the key's real y to know how much room is above it.
  private static func row(y: CGFloat, style: RimeKeyboardStyle, keys: [RimeKeyboardKey]) -> RimeKeyboardRow {
    let width = keys.last.map { $0.frame.maxX + style.sideMargin } ?? 0
    let height = keys.first?.frame.height ?? style.keyHeight
    let placed = keys.map { key in
      RimeKeyboardKey(kind: key.kind, label: key.label, accessibilityLabel: key.accessibilityLabel,
                      frame: CGRect(x: key.frame.minX, y: y, width: key.frame.width, height: height), isAuxiliary: key.isAuxiliary, isCore: key.isCore)
    }
    return RimeKeyboardRow(frame: CGRect(x: 0, y: y, width: width, height: height), keys: placed)
  }

  private static func letterRow1(width: CGFloat, shift: RimeShiftState,
                                 style: RimeKeyboardStyle) -> [RimeKeyboardKey] {
    let letterWidth = style.letterKeyWidth(for: width)
    return Array("qwertyuiop").enumerated().map { index, character in
      let x = style.sideMargin + CGFloat(index) * (letterWidth + style.horizontalGap)
      return characterKey(character, uppercase: shift.isUppercase,
                          frame: CGRect(x: x, y: 0, width: letterWidth, height: style.keyHeight))
    }
  }

  /// The second letter row is **centred**, not merely pushed right by a constant: nine keys and
  /// eight gaps, centred in the keyboard width. Measured: 29.455 pt from the edge against the
  /// capture's 29.35 (S3 §3's "21.05 pt indent", which is half a slot to within 0.1 pt) — and it
  /// keeps the row symmetric, which a fixed indent of 21.05 does not (it leaves 21.26 on the right).
  private static func letterRow2(width: CGFloat, shift: RimeShiftState,
                                 style: RimeKeyboardStyle) -> [RimeKeyboardKey] {
    let letterWidth = style.letterKeyWidth(for: width)
    let keyCount = 9
    let rowWidth = CGFloat(keyCount) * letterWidth + CGFloat(keyCount - 1) * style.horizontalGap
    let start = (width - rowWidth) / 2
    return Array("asdfghjkl").enumerated().map { index, character in
      let x = start + CGFloat(index) * (letterWidth + style.horizontalGap)
      return characterKey(character, uppercase: shift.isUppercase,
                          frame: CGRect(x: x, y: 0, width: letterWidth, height: style.keyHeight))
    }
  }

  private static func letterRow3(width: CGFloat, shift: RimeShiftState,
                                 style: RimeKeyboardStyle) -> [RimeKeyboardKey] {
    var keys: [RimeKeyboardKey] = []
    keys.append(RimeKeyboardKey(kind: .shift(shift),
                                frame: CGRect(x: style.sideMargin, y: 0,
                                              width: style.shiftWidth, height: style.keyHeight),
                                label: shift == .caps ? "⇪" : "⇧",
                                accessibilityLabel: shift == .caps ? RimeLocalization.text("Caps Lock") : RimeLocalization.text("Shift")))
    // Seven letter keys fill everything between shift and delete, with the standard gap.
    let available = width - 2 * style.sideMargin - style.shiftWidth - style.deleteWidth
      - 2 * style.sideKeyGap - 6 * style.horizontalGap
    let letterWidth = available / 7
    let start = style.sideMargin + style.shiftWidth + style.sideKeyGap
    for (index, character) in Array("zxcvbnm").enumerated() {
      let x = start + CGFloat(index) * (letterWidth + style.horizontalGap)
      keys.append(characterKey(character, uppercase: shift.isUppercase,
                               frame: CGRect(x: x, y: 0, width: letterWidth, height: style.keyHeight)))
    }
    keys.append(RimeKeyboardKey(kind: .delete,
                                frame: CGRect(x: width - style.sideMargin - style.deleteWidth, y: 0,
                                              width: style.deleteWidth, height: style.keyHeight),
                                label: "⌫", accessibilityLabel: RimeLocalization.text("Delete")))
    return keys
  }

  private static func plainRow(_ characters: [String], width: CGFloat,
                               style: RimeKeyboardStyle) -> [RimeKeyboardKey] {
    let keyWidth = style.letterKeyWidth(for: width)
    return characters.enumerated().map { index, character in
      let x = style.sideMargin + CGFloat(index) * (keyWidth + style.horizontalGap)
      return RimeKeyboardKey(kind: .character(character),
                             frame: CGRect(x: x, y: 0, width: keyWidth, height: style.keyHeight),
                             label: character, accessibilityLabel: character)
    }
  }

  /// The numbers and symbols third row is not the letter grid with different labels (S3 §3.2): its
  /// five middle keys are wider than a letter key. The two outer keys keep their measured widths and
  /// the middle five share what is left, so the row still ends exactly at the right margin.
  private static func specialThirdRow(_ characters: [String], width: CGFloat,
                                      layer: RimeKeyboardLayer,
                                      style: RimeKeyboardStyle,
                                      outerGap: CGFloat? = nil) -> [RimeKeyboardKey] {
    var keys: [RimeKeyboardKey] = []
    keys.append(RimeKeyboardKey(kind: .layer(layer),
                                frame: CGRect(x: style.sideMargin, y: 0,
                                              width: style.layerKeyWidth, height: style.keyHeight),
                                label: layer.switchLabel,
                                accessibilityLabel: layer.accessibilityLabel))
    let edgeGap = outerGap ?? style.horizontalGap
    let middleWidth = (width - 2 * style.sideMargin - style.layerKeyWidth - style.deleteWidth
      - 2 * edgeGap - CGFloat(characters.count - 1) * style.horizontalGap)
      / CGFloat(characters.count)
    var x = style.sideMargin + style.layerKeyWidth + edgeGap
    for character in characters {
      keys.append(RimeKeyboardKey(kind: .character(character),
                                  frame: CGRect(x: x, y: 0, width: middleWidth, height: style.keyHeight),
                                  label: character, accessibilityLabel: character))
      x += middleWidth + style.horizontalGap
    }
    keys.append(RimeKeyboardKey(kind: .delete,
                                frame: CGRect(x: width - style.sideMargin - style.deleteWidth, y: 0,
                                              width: style.deleteWidth, height: style.keyHeight),
                                label: "⌫", accessibilityLabel: RimeLocalization.text("Delete")))
    return keys
  }

  /// The bottom row supports optional keys beside Space. The second slot holds the
  /// 中/英 key when the schema has an 中英 state (S3 §5), and the emoji key otherwise — an emoji key
  /// with no panel behind it is a key that does nothing, which is worse than one that works.
  private static func bottomRow(width: CGFloat, layer: RimeKeyboardLayer,
                                style: RimeKeyboardStyle,
                                returnKey: RimeReturnKey,
                                language: RimeLanguageKey?,
                                auxiliaryPrefix: String?,
                                leftSpaceKey: RimeSpaceSideKey,
                                rightSpaceKey: RimeSpaceSideKey,
                                chineseInputOnly: Bool) -> [RimeKeyboardKey] {
    var keys: [RimeKeyboardKey] = []
    var x = style.sideMargin
    keys.append(RimeKeyboardKey(kind: .layer(layer),
                                frame: CGRect(x: x, y: 0, width: style.layerKeyWidth,
                                              height: style.keyHeight),
                                label: layer.switchLabel,
                                accessibilityLabel: layer.accessibilityLabel))
    x += style.layerKeyWidth + style.horizontalGap
    if !chineseInputOnly {
      if let language {
        keys.append(RimeKeyboardKey(kind: .language(language),
                                    frame: CGRect(x: x, y: 0, width: style.emojiKeyWidth,
                                                  height: style.keyHeight),
                                    label: language.label,
                                    accessibilityLabel: language.isASCII ? RimeLocalization.text("Switch to Chinese input") : RimeLocalization.text("Switch to English input")))
      } else {
        keys.append(RimeKeyboardKey(kind: .emoji,
                                    frame: CGRect(x: x, y: 0, width: style.emojiKeyWidth,
                                                  height: style.keyHeight),
                                    label: "☺", accessibilityLabel: RimeLocalization.text("Emoji")))
      }
      x += style.emojiKeyWidth + style.horizontalGap
    }
    let leftInput = leftSpaceKey.input(auxiliaryPrefix: auxiliaryPrefix)
    let rightInput = rightSpaceKey.input(auxiliaryPrefix: auxiliaryPrefix)
    let extraKeyCount = CGFloat([leftInput, rightInput].compactMap { $0 }.count)
    let punctuationWidth = min(style.letterKeyWidth(for: width),
                               max(1, (style.spaceKeyWidth - 1) / max(1, extraKeyCount) - style.horizontalGap))
    let availableSpaceWidth = style.spaceKeyWidth - extraKeyCount * (punctuationWidth + style.horizontalGap)
    // With no right-side key, restore the wider measured Return cap. On narrow
    // keyboards, limit the expansion so Space stays at least as wide as Return.
    let returnExpansion = rightInput == nil
      ? min(max(0, RimeKeyboardStyle.measured.returnKeyWidth - style.returnKeyWidth),
            max(0, (availableSpaceWidth - style.returnKeyWidth) / 2))
      : 0
    let returnWidth = style.returnKeyWidth + returnExpansion
    // Give the entire removed key and its gap to Space; keep Return unchanged.
    let recoveredWidth = chineseInputOnly ? style.emojiKeyWidth + style.horizontalGap : 0
    let spaceWidth = availableSpaceWidth - returnExpansion + recoveredWidth
    func appendSideKey(_ configuration: RimeSpaceSideKey, input: String?) {
      guard let input else { return }
      let isAuxiliary = configuration.mode == .auxiliary
      keys.append(RimeKeyboardKey(kind: .character(input),
                                  frame: CGRect(x: x, y: 0, width: punctuationWidth, height: style.keyHeight),
                                  label: input,
                                  accessibilityLabel: isAuxiliary ? RimeLocalization.text("Auxiliary prefix \(input)") : input,
                                  isAuxiliary: isAuxiliary))
      x += punctuationWidth + style.horizontalGap
    }
    appendSideKey(leftSpaceKey, input: leftInput)
    keys.append(RimeKeyboardKey(kind: .space,
                                frame: CGRect(x: x, y: 0, width: spaceWidth,
                                              height: style.keyHeight),
                                label: "", accessibilityLabel: RimeLocalization.text("Space")))
    x += spaceWidth + style.horizontalGap
    appendSideKey(rightSpaceKey, input: rightInput)
    keys.append(RimeKeyboardKey(kind: .returnKey,
                                frame: CGRect(x: x, y: 0, width: returnWidth,
                                              height: style.keyHeight),
                                label: returnKey.label,
                                accessibilityLabel: returnKey.label))
    return keys
  }

  private static func globeRow(width: CGFloat, style: RimeKeyboardStyle) -> [RimeKeyboardKey] {
    let keyWidth = style.letterKeyWidth(for: width)
    return [RimeKeyboardKey(kind: .globe,
                            frame: CGRect(x: style.sideMargin, y: 0, width: keyWidth,
                                          height: style.globeRowHeight),
                            label: "🌐", accessibilityLabel: RimeLocalization.text("Next keyboard"))]
  }

  private static func characterKey(_ character: Character, uppercase: Bool,
                                   frame: CGRect) -> RimeKeyboardKey {
    let text = uppercase ? String(character).uppercased() : String(character)
    return RimeKeyboardKey(kind: .character(text), frame: frame, label: text,
                           accessibilityLabel: text)
  }
}
