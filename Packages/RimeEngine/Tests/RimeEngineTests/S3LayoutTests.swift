import XCTest
import CoreGraphics
@testable import RimeEngine

/// S3 §9's layout invariants, and the geometry the spec fixes at 430 pt. These run on macOS because
/// the layout engine is pure geometry — the class of bug that killed the tracer's extension (a
/// constraint conflict) cannot happen in a value type, and the arithmetic can be checked without a
/// simulator.
final class S3LayoutTests: XCTestCase {
  func testSplitLettersDuplicateReachKeysAndSpaceWithoutChangingHeight() {
    let division = CGRect(x: 320, y: 0, width: 60, height: 350)
    let regular = RimeKeyboardLayoutEngine.layout(width: 700, style: .systemAligned)
    for shift in RimeShiftState.allCases {
      let split = RimeKeyboardLayoutEngine.layout(width: 700, shift: shift,
        inlineGlobe: true, style: .systemAligned, splitDivision: division)
      XCTAssertEqual(split.height, regular.height)
      let labels = split.rows.prefix(3).map { $0.keys.map(\.label).joined().lowercased() }
      XCTAssertEqual(labels, ["qwertyuiop", "asdfgghjkl", "⇧zxcvvbnm⌫"].enumerated().map {
        $0.offset == 2 && shift == .caps ? "⇪zxcvvbnm⌫" : $0.element
      })
      XCTAssertEqual(split.keys.filter { $0.kind == .space }.count, 2)
      XCTAssertEqual(split.keys.filter { $0.kind == .globe }.count, 1)
      for key in split.keys {
        XCTAssertTrue(key.frame.maxX <= division.minX || key.frame.minX >= division.maxX)
        XCTAssertGreaterThan(key.frame.width, 0)
        XCTAssertFalse(key.accessibilityLabel.isEmpty)
      }
    }
  }

  func testSplitAllLayersPreserveSideKeysAndAvoidAnAsymmetricDivision() {
    for width: CGFloat in [540, 669, 951] {
      let division = CGRect(x: width * 0.45, y: 0, width: 40, height: 350)
      for layer in RimeKeyboardLayer.allCases {
        for chineseOnly in [false, true] {
          let split = RimeKeyboardLayoutEngine.layout(width: width, layer: layer,
            language: RimeLanguageKey(label: "中", isASCII: false), inlineGlobe: true,
            style: .systemAligned, auxiliaryPrefix: ";",
            leftSpaceKey: RimeSpaceSideKey(mode: .character, character: ","),
            rightSpaceKey: RimeSpaceSideKey(mode: .auxiliary),
            chineseInputOnly: chineseOnly, splitDivision: division)
          let bottom = split.rows[3].keys
          XCTAssertEqual(bottom.filter { $0.kind == .space }.count, 2)
          XCTAssertEqual(bottom.filter { $0.kind == .character(";") && $0.isAuxiliary }.count, 1)
          XCTAssertEqual(bottom.filter { $0.kind == .character(",") }.count, 1)
          XCTAssertEqual(bottom.filter { if case .language = $0.kind { return true }; return false }.count,
                         chineseOnly ? 0 : 1)
          XCTAssertEqual(bottom.last?.kind, .returnKey)
          for row in split.rows {
            for key in row.keys {
              XCTAssertGreaterThan(key.frame.width, 0)
              XCTAssertGreaterThanOrEqual(key.frame.minX, 0)
              XCTAssertLessThanOrEqual(key.frame.maxX, width)
              XCTAssertTrue(key.frame.maxX <= division.minX || key.frame.minX >= division.maxX)
            }
            for (previous, next) in zip(row.keys, row.keys.dropFirst()) {
              XCTAssertGreaterThanOrEqual(next.frame.minX, previous.frame.maxX)
            }
          }
        }
      }
    }
  }

  func testUnusableSplitDivisionRetainsTheStandardLayout() {
    let original = RimeKeyboardLayoutEngine.layout(width: 430)
    for division in [CGRect(x: 200, y: 0, width: 100, height: 300),
                     CGRect(x: -10, y: 0, width: 10, height: 300)] {
      let layout = RimeKeyboardLayoutEngine.layout(width: 430, splitDivision: division)
      XCTAssertEqual(layout.keys, original.keys)
    }
  }

  func testInlineGlobeFitsAllLayersAndSupportedWidths() throws {
    for width: CGFloat in [320, 390, 430, 744, 1024] {
      for layer in RimeKeyboardLayer.allCases {
        for chineseOnly in [false, true] {
          var style = RimeKeyboardStyle.systemAligned
          style.spaceKeyWidth = width - 2 * style.sideMargin - 3 * style.horizontalGap
            - style.layerKeyWidth - style.emojiKeyWidth - style.returnKeyWidth
          let layout = RimeKeyboardLayoutEngine.layout(width: width, layer: layer,
            inlineGlobe: true, style: style,
            leftSpaceKey: .init(mode: .character), rightSpaceKey: .init(mode: .auxiliary),
            chineseInputOnly: chineseOnly)
          let baseline = RimeKeyboardLayoutEngine.layout(width: width, layer: layer, style: style)
          XCTAssertEqual(layout.height, baseline.height)
          XCTAssertEqual(layout.rows.count, 4)
          let bottom = layout.rows[3].keys
          XCTAssertEqual(bottom[1].kind, .globe)
          XCTAssertEqual(layout.keys.filter { $0.kind == .globe }.count, 1)
          let globe = try XCTUnwrap(bottom.first { $0.kind == .globe })
          XCTAssertEqual(globe.frame.height, style.keyHeight)
          XCTAssertFalse(globe.isCore)
          for key in bottom {
            XCTAssertGreaterThan(key.frame.width, 0)
            XCTAssertGreaterThanOrEqual(key.frame.minX, style.sideMargin)
            XCTAssertLessThanOrEqual(key.frame.maxX, width - style.sideMargin + 0.01)
          }
          for (left, right) in zip(bottom, bottom.dropFirst()) {
            XCTAssertEqual(right.frame.minX - left.frame.maxX, style.horizontalGap, accuracy: 0.01)
          }
        }
      }
    }
  }

  func testSwitchingInputModeUsesSeparateSideKeysAndRecoversSpace() throws {
    var preferences = RimeKeyboardPreferences(leftSpaceKey: .init(mode: .character, character: ";"),
                                             rightSpaceKey: .init(mode: .auxiliary))
    func bottomRow(isASCII: Bool) -> [RimeKeyboardKey] {
      let sides = preferences.spaceSideKeys(isASCII: isASCII)
      return RimeKeyboardLayoutEngine.layout(width: 390,
        language: RimeLanguageKey(label: isASCII ? "English" : "Chinese", isASCII: isASCII),
        auxiliaryPrefix: ",", leftSpaceKey: sides.left, rightSpaceKey: sides.right).rows[3].keys
    }
    let chinese = bottomRow(isASCII: false)
    let english = bottomRow(isASCII: true)
    XCTAssertTrue(chinese.contains { $0.isAuxiliary })
    XCTAssertFalse(english.contains { $0.isAuxiliary })
    XCTAssertFalse(english.contains { if case .character = $0.kind { return true }; return false })
    let chineseSpace = try XCTUnwrap(chinese.first { $0.kind == .space })
    let englishSpace = try XCTUnwrap(english.first { $0.kind == .space })
    XCTAssertGreaterThan(englishSpace.frame.width, chineseSpace.frame.width)
    preferences.englishRightSpaceKey = .init(mode: .character, character: ".")
    XCTAssertTrue(bottomRow(isASCII: true).contains { $0.kind == .character(".") && !$0.isAuxiliary })
    XCTAssertEqual(bottomRow(isASCII: false).map(\.kind), chinese.map(\.kind))
  }

  func testPunctuationLabelsPreserveInputAndAuxiliaryKeys() throws {
    let definitions = RimePunctuationKeyLabels(
      halfShape: [".": .map(["commit": .string("。")]),
                  ",": .string("，"), ";": .list([.string("；"), .string(";")]),
                  "\"": .map(["pair": .list([.string("“"), .string("”")])])],
      fullShape: [".": .string("．")])
    let labels = definitions.labels(isASCII: false, isFullShape: false, isAsciiPunctuation: false)
    let layout = RimeKeyboardLayoutEngine.layout(width: 430, layer: .numbers,
                                                 punctuationLabels: labels)
    let period = try XCTUnwrap(layout.keys.first { $0.kind == .character(".") })
    XCTAssertEqual(period.label, "。")
    XCTAssertEqual(period.accessibilityLabel, "。")
    XCTAssertEqual(labels["\""], "“”")
    XCTAssertEqual(labels[";"], "；")
    XCTAssertEqual(definitions.labels(isASCII: false, isFullShape: true,
                                      isAsciiPunctuation: false)["."], "．")
    XCTAssertEqual(definitions.labels(isASCII: true, isFullShape: true,
                                      isAsciiPunctuation: false)["."], "．")
    XCTAssertEqual(definitions.labels(isASCII: false, isFullShape: true,
                                      isAsciiPunctuation: true)["1"], "１")
    XCTAssertTrue(definitions.labels(isASCII: false, isFullShape: false,
                                     isAsciiPunctuation: true).isEmpty)
    let letters = RimeKeyboardLayoutEngine.layout(
      width: 430, auxiliaryPrefix: ",", leftSpaceKey: RimeSpaceSideKey(mode: .auxiliary),
      punctuationLabels: labels)
    XCTAssertEqual(letters.keys.first { $0.isAuxiliary }?.label, ",")
  }

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

  func testChineseOnlyGivesExactlyTheRemovedKeyWidthAndGapToSpace() throws {
    let configurations = [RimeSpaceSideKey(), RimeSpaceSideKey(mode: .character, character: ";"),
                          RimeSpaceSideKey(mode: .auxiliary)]
    for width: CGFloat in [320, 375, 430] {
      var fitted = RimeKeyboardStyle.systemAligned
      fitted.spaceKeyWidth = width - 2 * fitted.sideMargin - 3 * fitted.horizontalGap
        - fitted.layerKeyWidth - fitted.emojiKeyWidth - fitted.returnKeyWidth
      for layer in RimeKeyboardLayer.allCases {
        for left in configurations {
          for right in configurations {
            for language in [nil, RimeLanguageKey(label: "English", isASCII: true)] {
              let original = RimeKeyboardLayoutEngine.layout(width: width, layer: layer,
                language: language, style: fitted, auxiliaryPrefix: ",", leftSpaceKey: left,
                rightSpaceKey: right).rows[3].keys
              let keys = RimeKeyboardLayoutEngine.layout(width: width, layer: layer,
                language: language, style: fitted, auxiliaryPrefix: ",", leftSpaceKey: left,
                rightSpaceKey: right, chineseInputOnly: true).rows[3].keys
              XCTAssertEqual(keys.count, original.count - 1)
              XCTAssertFalse(keys.contains { key in
                switch key.kind { case .language, .emoji: return true; default: return false }
              })
              let space = try XCTUnwrap(keys.first { $0.kind == .space })
              let originalSpace = try XCTUnwrap(original.first { $0.kind == .space })
              XCTAssertEqual(space.frame.width - originalSpace.frame.width,
                             fitted.emojiKeyWidth + fitted.horizontalGap, accuracy: 0.01)
              let enter = try XCTUnwrap(keys.last)
              let originalEnter = try XCTUnwrap(original.last)
              XCTAssertEqual(enter.frame.minX, originalEnter.frame.minX, accuracy: 0.01)
              XCTAssertEqual(enter.frame.size, originalEnter.frame.size)
              for (previous, next) in zip(keys, keys.dropFirst()) {
                XCTAssertGreaterThan(previous.frame.width, 0)
                XCTAssertEqual(next.frame.minX - previous.frame.maxX, fitted.horizontalGap, accuracy: 0.01)
              }
            }
          }
        }
      }
    }
  }

  func testIndependentSideKeysAcrossLayersAndPhoneWidths() throws {
    let configurations = [RimeSpaceSideKey(), RimeSpaceSideKey(mode: .character, character: ";"),
                          RimeSpaceSideKey(mode: .auxiliary)]
    for width: CGFloat in [320, 375, 430] {
      var fitted = RimeKeyboardStyle.systemAligned
      fitted.spaceKeyWidth = width - 2 * fitted.sideMargin - 3 * fitted.horizontalGap
        - fitted.layerKeyWidth - fitted.emojiKeyWidth - fitted.returnKeyWidth
      for layer in RimeKeyboardLayer.allCases {
        for left in configurations {
          for right in configurations {
            let keys = RimeKeyboardLayoutEngine.layout(width: width, layer: layer, style: fitted,
              auxiliaryPrefix: ",", leftSpaceKey: left, rightSpaceKey: right).rows[3].keys
            let spaceIndex = try XCTUnwrap(keys.firstIndex { $0.kind == .space })
            let count = (left.mode == .disabled ? 0 : 1) + (right.mode == .disabled ? 0 : 1)
            XCTAssertEqual(keys.count, 4 + count)
            let enter = try XCTUnwrap(keys.last)
            XCTAssertEqual(keys[spaceIndex].frame.width + enter.frame.width,
              fitted.spaceKeyWidth + fitted.returnKeyWidth
                - CGFloat(count) * (fitted.letterKeyWidth(for: width) + fitted.horizontalGap),
              accuracy: 0.01)
            if right.mode == .disabled {
              XCTAssertGreaterThan(enter.frame.width, fitted.returnKeyWidth)
              XCTAssertLessThanOrEqual(enter.frame.width, RimeKeyboardStyle.measured.returnKeyWidth)
              XCTAssertGreaterThanOrEqual(keys[spaceIndex].frame.width + 0.01, enter.frame.width)
              if width == 430 {
                XCTAssertEqual(enter.frame.width, 96.4, accuracy: 0.01)
              }
            } else {
              XCTAssertEqual(enter.frame.width, fitted.returnKeyWidth, accuracy: 0.01)
            }
            XCTAssertEqual(try XCTUnwrap(keys.last).frame.maxX, width - fitted.sideMargin, accuracy: 0.01)
            for (previous, next) in zip(keys, keys.dropFirst()) {
              XCTAssertGreaterThan(previous.frame.width, 0)
              XCTAssertEqual(next.frame.minX - previous.frame.maxX, fitted.horizontalGap, accuracy: 0.01)
            }
            if left.mode != .disabled {
              XCTAssertEqual(keys[spaceIndex - 1].kind, .character(left.mode == .auxiliary ? "," : ";"))
              XCTAssertEqual(keys[spaceIndex - 1].isAuxiliary, left.mode == .auxiliary)
            }
            if right.mode != .disabled {
              XCTAssertEqual(keys[spaceIndex + 1].kind, .character(right.mode == .auxiliary ? "," : ";"))
              XCTAssertEqual(keys[spaceIndex + 1].isAuxiliary, right.mode == .auxiliary)
            }
          }
        }
      }
    }
  }

  func testAuxiliaryKeyKeepsReturnPositionAndCanSwapSides() throws {
    let baseline = layout().rows[3].keys
    let originalReturn = try XCTUnwrap(baseline.last).frame
    for side in RimeKeyboardPreferences.AuxiliaryKeySide.allCases {
      let keys = RimeKeyboardLayoutEngine.layout(width: referenceWidth, style: style,
                                                   auxiliaryPrefix: ";",
                                                   leftSpaceKey: RimeSpaceSideKey(mode: side == .left ? .auxiliary : .disabled),
                                                   rightSpaceKey: RimeSpaceSideKey(mode: side == .right ? .auxiliary : .disabled)).rows[3].keys
      XCTAssertEqual(keys.count, baseline.count + 1)
      let actionFrame = try XCTUnwrap(keys.last).frame
      XCTAssertEqual(actionFrame.minX, originalReturn.minX, accuracy: 0.01)
      XCTAssertEqual(actionFrame.width, originalReturn.width, accuracy: 0.01)
      let spaceIndex = try XCTUnwrap(keys.firstIndex { if case .space = $0.kind { return true }; return false })
      let auxiliaryIndex = try XCTUnwrap(keys.firstIndex { $0.isAuxiliary })
      XCTAssertEqual(auxiliaryIndex, spaceIndex + (side == .right ? 1 : -1))
      XCTAssertTrue(keys[auxiliaryIndex].isAuxiliary)
      XCTAssertEqual(keys[auxiliaryIndex].frame.width, style.letterKeyWidth(for: referenceWidth), accuracy: 0.01)
    }
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

    // Disabled side keys leave the entire space region available.
    let bottom = letters.rows[3]
    for (key, expected) in zip(bottom.keys, [43.4, 43.1, 201.4, 96.4]) {
      XCTAssertEqual(key.frame.width, expected, accuracy: 0.01)
    }
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
    XCTAssertEqual(numbers.rows[2].keys.map(\.label), ["#+=", ".", ",", "?", "!", "'", "⌫"])
    XCTAssertEqual(numbers.rows[2].keys[1].frame.minX - numbers.rows[2].keys[0].frame.maxX,
                   style.sideKeyGap, accuracy: 0.01)
    XCTAssertEqual(numbers.rows[2].keys[6].frame.minX - numbers.rows[2].keys[5].frame.maxX,
                   style.sideKeyGap, accuracy: 0.01)
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
    XCTAssertEqual(try XCTUnwrap(numbers.rows[2].keys.first).accessibilityLabel, RimeLocalization.text("Symbols"))
    XCTAssertEqual(try XCTUnwrap(symbols.rows[2].keys.first).label, "123")
    XCTAssertEqual(try XCTUnwrap(symbols.rows[2].keys.first).accessibilityLabel, RimeLocalization.text("Numbers"))
  }

  func testShiftStatesChangeTheLabelsAndKeepTheGeometry() throws {
    let off = layout(shift: .off)
    let on = layout(shift: .on)
    let caps = layout(shift: .caps)

    XCTAssertEqual(off.rows[0].keys[0].label, "q")
    XCTAssertEqual(on.rows[0].keys[0].label, "Q")
    XCTAssertEqual(caps.rows[0].keys[0].label, "Q")
    XCTAssertEqual(try XCTUnwrap(off.rows[2].keys.first).label, "⇧")
    XCTAssertEqual(try XCTUnwrap(off.rows[2].keys.first).accessibilityLabel, RimeLocalization.text("Shift"))
    XCTAssertEqual(try XCTUnwrap(caps.rows[2].keys.first).label, "⇪")
    XCTAssertEqual(try XCTUnwrap(caps.rows[2].keys.first).accessibilityLabel, RimeLocalization.text("Caps Lock"))

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
    XCTAssertEqual(globe.keys[0].accessibilityLabel, RimeLocalization.text("Next keyboard"))
  }

  func testTheActionKeyCarriesItsLabelAndState() throws {
    let search = layout(returnKey: RimeReturnKey(label: RimeReturnKey.Kind.search.label,
                                                 isEnabled: false))
    let key = try XCTUnwrap(search.rows[3].keys.last)
    XCTAssertEqual(key.label, RimeLocalization.text("Search"))
    XCTAssertEqual(key.accessibilityLabel, RimeLocalization.text("Search"))
    XCTAssertFalse(search.returnKey.isEnabled, "the disabled state is data, not a colour in the view")
    XCTAssertEqual(RimeReturnKey.Kind.allCases.count, 10)
    XCTAssertTrue(RimeReturnKey.Kind.allCases.allSatisfy { !$0.label.isEmpty })
  }

  /// S3 §5's 中/英 key, in the bottom row's second slot: the key count stays unchanged, and the slot
  /// holds a key that works rather than an emoji key with no panel behind it (D5).
  func testTheLanguageKeyTakesTheEmojiSlotWhenTheSchemaHasOne() throws {
    let language = RimeLanguageKey(label: "中文", isASCII: false)
    let withLanguage = RimeKeyboardLayoutEngine.layout(width: referenceWidth, layer: .letters,
                                                       language: language, style: style)
    let bottom = withLanguage.rows[3]
    XCTAssertEqual(bottom.keys.count, 4)
    XCTAssertEqual(bottom.keys.map(\.frame.width), layout().rows[3].keys.map(\.frame.width),
                   "the language key preserves the bottom row geometry")
    XCTAssertEqual(bottom.keys[1].label, "中文")
    XCTAssertEqual(bottom.keys[1].accessibilityLabel, RimeLocalization.text("Switch to English input"))
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
    XCTAssertEqual(western.rows[3].keys[1].accessibilityLabel, RimeLocalization.text("Switch to Chinese input"))

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
          XCTAssertTrue(layout.keys.contains { $0.accessibilityLabel == RimeLocalization.text("Space") })
          XCTAssertTrue(layout.keys.contains { $0.accessibilityLabel == RimeLocalization.text("Delete") })
        }
      }
    }
  }
}
