import XCTest
import CoreGraphics
@testable import RimeEngine

/// S3 §9's layout invariants, and the geometry the spec fixes at 430 pt. These run on macOS because
/// the layout engine is pure geometry — the class of bug that killed the tracer's extension (a
/// constraint conflict) cannot happen in a value type, and the arithmetic can be checked without a
/// simulator.
final class S3LayoutTests: XCTestCase {
  private let referenceWidth: CGFloat = 430
  private let style = RimeKeyboardStyle.measured

  private func layout(_ layer: RimeKeyboardLayer = .letters,
                      shift: RimeShiftState = .off,
                      globe: Bool = false,
                      width: CGFloat? = nil,
                      returnKey: RimeReturnKey = RimeReturnKey()) -> RimeKeyboardLayout {
    RimeKeyboardLayoutEngine.layout(width: width ?? referenceWidth, layer: layer, shift: shift,
                                    returnKey: returnKey, needsGlobeRow: globe, style: style)
  }

  // MARK: The measured reference

  func testTheMeasuredKeyWidthsComeBackAt430Points() throws {
    XCTAssertEqual(style.letterKeyWidth(for: referenceWidth), 32.6, accuracy: 0.05,
                   "S3 §3.1's formula must reproduce the measurement")

    let letters = layout()
    let firstRow = try XCTUnwrap(letters.rows.first)
    XCTAssertEqual(firstRow.keys.count, 10)
    XCTAssertEqual(firstRow.keys[0].frame.minX, 8.3, accuracy: 0.01)
    XCTAssertEqual(firstRow.keys[0].frame.width, 32.6, accuracy: 0.05)
    XCTAssertEqual(try XCTUnwrap(firstRow.keys.last).frame.maxX, referenceWidth - 8.3, accuracy: 0.01)

    // The second letter row is indented half a slot.
    let secondRow = letters.rows[1]
    XCTAssertEqual(secondRow.keys.count, 9)
    // Centred rather than pushed right by a constant: derived 29.455 against the capture's 29.35,
    // a 0.1 pt difference inside the 1 pt tolerance, and symmetric where a fixed 21.05 indent
    // would leave 21.26 on the right.
    XCTAssertEqual(secondRow.keys[0].frame.minX, 29.35, accuracy: 0.2)
    XCTAssertEqual(try XCTUnwrap(secondRow.keys.last).frame.maxX, referenceWidth - 29.35, accuracy: 0.3)

    // Shift and delete keep their measured widths, with the wider gap to the letter block.
    let thirdRow = letters.rows[2]
    XCTAssertEqual(thirdRow.keys.count, 9)
    XCTAssertEqual(thirdRow.keys[0].frame.width, 45.1, accuracy: 0.01)
    XCTAssertEqual(thirdRow.keys[1].frame.minX, 8.3 + 45.1 + 18.4, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(thirdRow.keys.last).frame.width, 45.4, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(thirdRow.keys.last).frame.maxX, referenceWidth - 8.3, accuracy: 0.01)
    // The seven letters that fill the middle land on the letter width.
    XCTAssertEqual(thirdRow.keys[1].frame.width, 32.6, accuracy: 0.1)

    // The bottom row's four measured widths.
    let bottom = letters.rows[3]
    XCTAssertEqual(bottom.keys.map(\.frame.width), [43.4, 43.1, 201.4, 96.4])
    XCTAssertEqual(try XCTUnwrap(bottom.keys.last).frame.maxX, referenceWidth - 8.3, accuracy: 0.01)
  }

  /// Two places where the spec's own numbers do not close, recorded rather than smoothed over: the
  /// layout derives from the formula and the *measurements* are what the next capture has to settle.
  func testTheSpecsOwnArithmeticDiscrepanciesAreRecorded() {
    // key width + gap = 42.3, while the measured slot pitch is 42.1.
    XCTAssertEqual(style.slotPitch(for: referenceWidth), 42.3, accuracy: 0.02)
    // The parts sum to 333.0 while the measured keyboard height is 332.7.
    let sum = style.candidateSlotHeight + 4 * style.keyHeight + 3 * style.rowGap + style.bottomInset
    XCTAssertEqual(sum, 333.0, accuracy: 0.01)
    XCTAssertEqual(layout().height, sum, accuracy: 0.001,
                   "S3 §3.1: the height is the sum of its parts, not a guess")
  }

  // MARK: Invariants

  /// The class of bug that killed the tracer's extension, as arithmetic: every row fits exactly
  /// between the margins, nothing overlaps, and every key has a positive size.
  ///
  /// The one exception is by design and is asserted as such: the second letter row is indented by
  /// half a slot (S3 §3), so it does not start at the left margin — it still *ends* at the right one.
  func testEveryRowTilesTheWidthWithoutOverlapping() throws {
    for layer in RimeKeyboardLayer.allCases {
      for shift in RimeShiftState.allCases {
        for globe in [false, true] {
          let grid = layout(layer, shift: shift, globe: globe)
          for (index, row) in grid.rows.enumerated() where index < 4 {
            let keys = row.keys
            XCTAssertFalse(keys.isEmpty, "\(layer) row \(index) is empty")
            // The second letter row is centred, so its inset is half a slot on both sides — the
            // measurement is 21.05 and the derived value is 21.155, which is inside the tolerance
            // the geometry check uses.
            let isCentredRow = layer == .letters && index == 1
            let expectedLeft = isCentredRow
              ? style.sideMargin + style.secondRowIndent : style.sideMargin
            let expectedRight = isCentredRow
              ? referenceWidth - style.sideMargin - style.secondRowIndent
              : referenceWidth - style.sideMargin
            XCTAssertEqual(keys[0].frame.minX, expectedLeft, accuracy: 0.5,
                           "\(layer) row \(index) starts in the wrong place")
            XCTAssertEqual(try XCTUnwrap(keys.last).frame.maxX, expectedRight, accuracy: 0.5,
                           "\(layer) row \(index) does not end where it should")
            for (previous, next) in zip(keys, keys.dropFirst()) {
              XCTAssertGreaterThanOrEqual(next.frame.minX, previous.frame.maxX,
                                          "\(layer) row \(index): keys overlap")
            }
            for key in keys {
              XCTAssertEqual(key.frame.height, style.keyHeight, accuracy: 0.01)
              XCTAssertGreaterThan(key.frame.width, 0)
            }
          }
        }
      }
    }
  }

  func testRowsStackWithoutGapsOrOverlapsAndFitTheHeight() throws {
    let layout = layout(globe: true)
    var expectedY = style.candidateSlotHeight
    for row in layout.rows {
      XCTAssertEqual(row.frame.minY, expectedY, accuracy: 0.01)
      let rowHeight = row.keys.first?.frame.height ?? 0
      expectedY += rowHeight + style.rowGap
    }
    XCTAssertLessThanOrEqual(expectedY - style.rowGap + style.bottomInset, layout.height + 0.001)
    XCTAssertGreaterThan(layout.height, 0)
    XCTAssertEqual(layout.candidateSlot.height, 39.7, accuracy: 0.01)
    XCTAssertEqual(layout.candidateSlot.width, referenceWidth, accuracy: 0.01)
  }

  /// S3 §3.1 marks the second width [verify]: this is the formula's consistency, not a measurement.
  func testASecondWidthFollowsTheSameFormula() throws {
    let width: CGFloat = 393
    let narrow = layout(width: width)
    XCTAssertEqual(style.letterKeyWidth(for: width), 28.91, accuracy: 0.01)
    let firstRow = try XCTUnwrap(narrow.rows.first)
    XCTAssertEqual(firstRow.keys[0].frame.minX, 8.3, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(firstRow.keys.last).frame.maxX, width - 8.3, accuracy: 0.01)
    for (previous, next) in zip(firstRow.keys, firstRow.keys.dropFirst()) {
      XCTAssertEqual(next.frame.minX - previous.frame.maxX, 9.7, accuracy: 0.01,
                     "gaps are fixed; the keys flex")
    }
    // The height does not depend on the width at all.
    XCTAssertEqual(narrow.height, layout().height, accuracy: 0.001)
  }

  // MARK: Layers and states

  func testEachLayerHasTheShapeTheSpecDescribes() throws {
    let letters = layout(.letters)
    XCTAssertEqual(letters.rows.map { $0.keys.count }, [10, 9, 9, 4])

    let numbers = layout(.numbers)
    XCTAssertEqual(numbers.rows.map { $0.keys.count }, [10, 10, 7, 4])
    XCTAssertEqual(numbers.rows[0].keys.map(\.label).joined(), "1234567890")
    XCTAssertEqual(numbers.rows[1].keys.map(\.label).joined(), "-/:;()$&@\"")
    // The numbers third row's middle keys are wider than a letter key — the difference the spec
    // says a single parametric grid gets wrong.
    XCTAssertGreaterThan(numbers.rows[2].keys[1].frame.width, style.letterKeyWidth(for: referenceWidth))
    XCTAssertEqual(try XCTUnwrap(numbers.rows[3].keys.first).label, "ABC")

    let symbols = layout(.symbols)
    XCTAssertEqual(symbols.rows.map { $0.keys.count }, [10, 10, 7, 4])
    XCTAssertEqual(symbols.rows[0].keys.map(\.label).joined(), "[]{}#%^*+=")
    XCTAssertEqual(try XCTUnwrap(symbols.rows[3].keys.first).label, "ABC")
    XCTAssertEqual(try XCTUnwrap(letters.rows[3].keys.first).label, "123")

    // The third row's switch key goes to the other punctuation layer, not to the letters — the
    // numbers layer carries `#+=` and the symbols layer carries `123` (S3 §3.2).
    XCTAssertEqual(try XCTUnwrap(numbers.rows[2].keys.first).label, "#+=")
    XCTAssertEqual(try XCTUnwrap(numbers.rows[2].keys.first).accessibilityLabel, "符号")
    XCTAssertEqual(try XCTUnwrap(symbols.rows[2].keys.first).label, "123")
    XCTAssertEqual(try XCTUnwrap(symbols.rows[2].keys.first).accessibilityLabel, "数字")
  }

  func testShiftStatesChangeTheLabelsAndKeepTheGeometry() throws {
    let off = layout(shift: .off)
    let on = layout(shift: .on)
    let caps = layout(shift: .caps)

    XCTAssertEqual(off.rows[0].keys[0].label, "q")
    XCTAssertEqual(on.rows[0].keys[0].label, "Q")
    XCTAssertEqual(caps.rows[0].keys[0].label, "Q")
    XCTAssertEqual(try XCTUnwrap(off.rows[2].keys.first).label, "⇧")
    XCTAssertEqual(try XCTUnwrap(off.rows[2].keys.first).accessibilityLabel, "大写")
    XCTAssertEqual(try XCTUnwrap(caps.rows[2].keys.first).label, "⇪")
    XCTAssertEqual(try XCTUnwrap(caps.rows[2].keys.first).accessibilityLabel, "大写锁定")

    // One-shot versus caps is a state change, not a layout change.
    XCTAssertEqual(off.rows[0].keys[0].frame, on.rows[0].keys[0].frame)
    XCTAssertEqual(on.rows[0].keys[0].frame, caps.rows[0].keys[0].frame)

    XCTAssertEqual(RimeShiftState.off.tapped(), .on)
    XCTAssertEqual(RimeShiftState.on.tapped(), .off)
    XCTAssertEqual(RimeShiftState.off.doubleTapped(), .caps)
  }

  func testTheGlobeRowAddsItsHeightAndOneKey() throws {
    let without = layout(globe: false)
    let with = layout(globe: true)
    XCTAssertEqual(with.rows.count, without.rows.count + 1)
    XCTAssertEqual(with.height - without.height, style.globeRowHeight + style.rowGap, accuracy: 0.001)
    let globe = try XCTUnwrap(with.rows.last)
    XCTAssertEqual(globe.keys.count, 1)
    XCTAssertEqual(globe.keys[0].frame.height, style.globeRowHeight, accuracy: 0.01)
    XCTAssertEqual(globe.keys[0].accessibilityLabel, "下一个键盘")
  }

  func testTheActionKeyCarriesItsLabelAndState() throws {
    let search = layout(returnKey: RimeReturnKey(label: RimeReturnKey.Kind.search.label,
                                                 isEnabled: false))
    let key = try XCTUnwrap(search.rows[3].keys.last)
    XCTAssertEqual(key.label, "搜索")
    XCTAssertEqual(key.accessibilityLabel, "搜索")
    XCTAssertFalse(search.returnKey.isEnabled, "the disabled state is data, not a colour in the view")
    XCTAssertEqual(RimeReturnKey.Kind.allCases.count, 10)
    XCTAssertTrue(RimeReturnKey.Kind.allCases.allSatisfy { !$0.label.isEmpty })
  }

  /// S3 §5's 中/英 key, in the measured bottom row's second slot: four keys stay four, and the slot
  /// holds a key that works rather than an emoji key with no panel behind it (D5).
  func testTheLanguageKeyTakesTheEmojiSlotWhenTheSchemaHasOne() throws {
    let language = RimeLanguageKey(label: "中文", isASCII: false)
    let withLanguage = RimeKeyboardLayoutEngine.layout(width: referenceWidth, layer: .letters,
                                                       language: language, style: style)
    let bottom = withLanguage.rows[3]
    XCTAssertEqual(bottom.keys.count, 4, "the measured row is four keys")
    XCTAssertEqual(bottom.keys.map(\.frame.width), [43.4, 43.1, 201.4, 96.4],
                   "and the widths are the measured ones, so the slot is unchanged")
    XCTAssertEqual(bottom.keys[1].label, "中文")
    XCTAssertEqual(bottom.keys[1].accessibilityLabel, "切换到英文")
    let key = bottom.keys[1]
    if case .language(let value) = key.kind {
      XCTAssertFalse(value.isASCII)
    } else {
      XCTFail("expected a language key in the second slot, got \(key.kind)")
    }

    // The other state says the other thing, and the key shows the state the user is in.
    let western = RimeKeyboardLayoutEngine.layout(
      width: referenceWidth, layer: .letters,
      language: RimeLanguageKey(label: "西文", isASCII: true), style: style)
    XCTAssertEqual(western.rows[3].keys[1].label, "西文")
    XCTAssertEqual(western.rows[3].keys[1].accessibilityLabel, "切换到中文")

    // Without a language key the slot keeps the emoji key, unchanged.
    XCTAssertEqual(layout().rows[3].keys[1].label, "☺")

    // A language key never raises a callout: it is a modifier key (S3 §5).
    XCTAssertFalse(RimeKeyFeedbackPolicy.raisesCallout(key, feedback: .standard))
  }

  // MARK: Accessibility

  func testEveryKeyIsLabelledForVoiceOver() {
    for layer in RimeKeyboardLayer.allCases {
      for shift in RimeShiftState.allCases {
        for globe in [false, true] {
          let layout = layout(layer, shift: shift, globe: globe)
          for key in layout.keys {
            XCTAssertFalse(key.accessibilityLabel.isEmpty,
                           "\(layer) \(shift) has an unlabelled key: \(key.kind)")
          }
          for key in layout.keys where key.isCharacter {
            XCTAssertEqual(key.accessibilityLabel, key.label,
                           "a character key is named by its own character")
            XCTAssertEqual(key.accessibilityLabel.count, 1)
          }
          // The action keys are named in the keyboard's language, not by their glyph.
          XCTAssertTrue(layout.keys.contains { $0.accessibilityLabel == "空格" })
          XCTAssertTrue(layout.keys.contains { $0.accessibilityLabel == "删除" })
        }
      }
    }
  }
}
