import UIKit

enum KeyboardKey: Hashable {
  case character(String)
  case shift
  case backspace
  case space
  case returnKey
  case numbers
  case letters
  case emoji
  case auxCode
  case globe
}

enum KeyLayer {
  case letters
  case numbers
}

/// One key grid row: keys with explicit widths, in key units.
struct KeyGridRow {
  enum Width {
    case units(CGFloat)
    /// Takes what is left in the row; the assumed value only sets the unit size.
    case remainder(assumed: CGFloat)
  }

  struct Item {
    let key: KeyboardKey?
    let width: Width
  }

  let items: [Item]
}

/// The key rows, laid out like the system keyboard: 10-9-9 keys, 1.5-unit modifiers, and a
/// space bar shortened to make room for the aux-code key on its right.
final class KeyboardKeyGrid: UIView {
  var onKey: ((KeyboardKey) -> Void)?

  private var rows: [KeyGridRow] = []
  private var rowButtons: [[KeyButton]] = []
  private var theme = KeyboardTheme.current(for: .default)
  private var currentLayer: KeyLayer = .letters
  private var asciiMode = false
  private var returnKeyLabel = "换行"
  private var showsGlobeRow = false
  private var builtForGlobeRow = false
  /// Last configuration actually applied. Restyling the whole grid on every keystroke (fonts,
  /// SF Symbol lookups, colours) was a measurable part of the input latency.
  private var applied: (layer: KeyLayer, asciiMode: Bool, returnKeyLabel: String,
                        showsGlobeRow: Bool, appearance: UIKeyboardAppearance)?

  func configure(theme: KeyboardTheme,
                 layer: KeyLayer,
                 asciiMode: Bool,
                 returnKeyLabel: String,
                 showsGlobeRow: Bool) {
    if let applied,
       applied.layer == layer,
       applied.asciiMode == asciiMode,
       applied.returnKeyLabel == returnKeyLabel,
       applied.showsGlobeRow == showsGlobeRow,
       applied.appearance == theme.appearance {
      return
    }
    applied = (layer, asciiMode, returnKeyLabel, showsGlobeRow, theme.appearance)

    self.theme = theme
    self.asciiMode = asciiMode
    self.returnKeyLabel = returnKeyLabel
    self.showsGlobeRow = showsGlobeRow
    if layer != currentLayer || builtForGlobeRow != showsGlobeRow || rowButtons.isEmpty {
      currentLayer = layer
      rebuild()
    } else {
      refreshAppearance()
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    var y: CGFloat = 0
    for (index, row) in rows.enumerated() {
      let isGlobeRow = showsGlobeRow && index == rows.count - 1
      let height = isGlobeRow ? KeyboardMetrics.globeRowHeight : KeyboardMetrics.keyHeight
      layout(row: row, buttons: rowButtons[index], originY: y, height: height)
      y += height + KeyboardMetrics.rowGap
    }
  }

  // MARK: - Rows

  private static let globeRow = KeyGridRow(items: [
    KeyGridRow.Item(key: .globe, width: .units(1.5)),
    KeyGridRow.Item(key: nil, width: .remainder(assumed: 8.5)),
  ])

  private static func rows(for layer: KeyLayer) -> [KeyGridRow] {
    func bottomRow(firstKey: KeyboardKey) -> KeyGridRow {
      KeyGridRow(items: [
        KeyGridRow.Item(key: firstKey, width: .units(1.25)),
        KeyGridRow.Item(key: .emoji, width: .units(1.25)),
        KeyGridRow.Item(key: .space, width: .remainder(assumed: 5.0)),
        KeyGridRow.Item(key: .auxCode, width: .units(1.5)),
        KeyGridRow.Item(key: .returnKey, width: .units(1.75)),
      ])
    }
    func letters(_ text: String) -> [KeyGridRow.Item] {
      text.map { KeyGridRow.Item(key: .character(String($0)), width: .units(1)) }
    }
    let halfSpacer = KeyGridRow.Item(key: nil, width: .units(0.5))

    switch layer {
    case .letters:
      return [
        KeyGridRow(items: letters("qwertyuiop")),
        KeyGridRow(items: [halfSpacer] + letters("asdfghjkl") + [halfSpacer]),
        KeyGridRow(items: [KeyGridRow.Item(key: .shift, width: .units(1.5))]
          + letters("zxcvbnm")
          + [KeyGridRow.Item(key: .backspace, width: .units(1.5))]),
        bottomRow(firstKey: .numbers),
      ]
    case .numbers:
      return [
        KeyGridRow(items: letters("1234567890")),
        KeyGridRow(items: [halfSpacer] + letters("-/:;()$&@\"") + [halfSpacer]),
        KeyGridRow(items: [KeyGridRow.Item(key: .letters, width: .units(1.5))]
          + letters(".,?!'")
          + [KeyGridRow.Item(key: .backspace, width: .units(1.5))]),
        bottomRow(firstKey: .letters),
      ]
    }
  }

  // MARK: - Building

  private func rebuild() {
    for buttons in rowButtons {
      for button in buttons {
        button.removeFromSuperview()
      }
    }
    rowButtons.removeAll()

    var built = Self.rows(for: currentLayer)
    if showsGlobeRow {
      built.append(Self.globeRow)
    }
    rows = built
    builtForGlobeRow = showsGlobeRow

    for row in rows {
      var buttons: [KeyButton] = []
      for item in row.items {
        let button = KeyButton(frame: .zero)
        button.key = item.key
        if let key = item.key {
          button.repeatsWhileHeld = (key == .backspace)
          button.addTarget(self, action: #selector(handleKeyPress(_:)), for: .primaryActionTriggered)
        } else {
          button.isUserInteractionEnabled = false
        }
        addSubview(button)
        buttons.append(button)
      }
      rowButtons.append(buttons)
    }
    refreshAppearance()
  }

  @objc private func handleKeyPress(_ sender: KeyButton) {
    guard let key = sender.key else { return }
    onKey?(key)
  }

  private func refreshAppearance() {
    for (rowIndex, row) in rows.enumerated() {
      for (itemIndex, item) in row.items.enumerated() {
        guard rowIndex < rowButtons.count, itemIndex < rowButtons[rowIndex].count else { continue }
        let button = rowButtons[rowIndex][itemIndex]
        guard let key = item.key else {
          button.backgroundColor = .clear
          continue
        }
        button.apply(theme: theme, style: style(for: key))
        applyContent(for: key, to: button)
      }
    }
  }

  private func style(for key: KeyboardKey) -> KeyButton.Style {
    switch key {
    case .character, .space, .auxCode:
      return .letter
    case .shift:
      return asciiMode ? .active : .special
    case .globe:
      return .plain
    default:
      return .special
    }
  }

  private func applyContent(for key: KeyboardKey, to button: KeyButton) {
    switch key {
    case .character(let value):
      button.setTitle(asciiMode ? value.uppercased() : value, pointSize: 24)
    case .space:
      button.setTitle("空格", pointSize: 16)
    case .auxCode:
      button.setTitle("辅码", pointSize: 16)
    case .returnKey:
      button.setTitle(returnKeyLabel, pointSize: 16)
    case .numbers:
      button.setTitle("123", pointSize: 16)
    case .letters:
      button.setTitle("ABC", pointSize: 16)
    case .shift:
      button.setSymbol(asciiMode ? "shift.fill" : "shift", pointSize: 20)
    case .backspace:
      button.setSymbol("delete.left", pointSize: 20)
    case .emoji:
      button.setSymbol("face.smiling", pointSize: 20)
    case .globe:
      button.setSymbol("globe", pointSize: 20)
    }
  }

  // MARK: - Layout

  private func layout(row: KeyGridRow, buttons: [KeyButton], originY: CGFloat, height: CGFloat) {
    let gap = KeyboardMetrics.keyGap
    let usable = bounds.width - 2 * KeyboardMetrics.sideMargin - gap * CGFloat(max(row.items.count - 1, 0))
    var assumedUnits: CGFloat = 0
    for item in row.items {
      switch item.width {
      case .units(let units): assumedUnits += units
      case .remainder(let assumed): assumedUnits += assumed
      }
    }
    guard assumedUnits > 0, usable > 0 else { return }
    let unit = usable / assumedUnits

    // The remainder item absorbs what the unit-sized items leave over. It is not necessarily
    // the last item in the row — the space bar has the aux-code and return keys to its right —
    // so this subtracts every unit-sized item, not only the ones already placed.
    var fixedUnits: CGFloat = 0
    for item in row.items {
      if case .units(let units) = item.width {
        fixedUnits += units
      }
    }
    let remainderWidth = max(usable - fixedUnits * unit, 0)

    var x = KeyboardMetrics.sideMargin
    for (index, item) in row.items.enumerated() {
      let width: CGFloat
      switch item.width {
      case .units(let units):
        width = units * unit
      case .remainder:
        width = remainderWidth
      }
      buttons[index].frame = CGRect(x: x, y: originY, width: max(width, 0), height: height)
      x += width + gap
    }
  }
}
