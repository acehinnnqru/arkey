import XCTest
import UIKit
import RimeEngine

/// S6 §2.1's keyboard layer, as it can only be checked on a simulator: the same invariants the engine's
/// macOS tests assert, but measured off the **views that actually lay out**. A frame that is right in
/// the model and wrong in the view is the failure this target exists to catch, and no test on the Mac
/// can see it.
final class KeyboardGeometryTests: XCTestCase {
  func testFoldPolicyRequiresAnActiveVerticalDivisionAndRejectsKnownClosedHinges() {
    let bounds = CGRect(x: 0, y: 0, width: 669, height: 213)
    let vertical = CGRect(x: 300, y: -100, width: 60, height: 600)
    XCTAssertNil(KeyboardFoldPolicy.splitDivision(bounds: bounds, isPartiallyOpen: nil, divisions: []))
    XCTAssertNil(KeyboardFoldPolicy.splitDivision(bounds: bounds, isPartiallyOpen: false, divisions: [vertical]))
    XCTAssertEqual(KeyboardFoldPolicy.splitDivision(bounds: bounds, isPartiallyOpen: nil, divisions: [vertical]), vertical)
    XCTAssertNil(KeyboardFoldPolicy.splitDivision(bounds: bounds, isPartiallyOpen: true, divisions: []))
    XCTAssertEqual(KeyboardFoldPolicy.splitDivision(bounds: bounds, isPartiallyOpen: true, divisions: [vertical]), vertical)
    XCTAssertNil(KeyboardFoldPolicy.splitDivision(bounds: bounds, isPartiallyOpen: nil,
      divisions: [CGRect(x: 0, y: 100, width: 669, height: 20)]))
    XCTAssertNil(KeyboardFoldPolicy.splitDivision(bounds: bounds, isPartiallyOpen: true,
      divisions: [CGRect(x: 0, y: -60, width: 669, height: 20)]))
    XCTAssertNil(KeyboardFoldPolicy.splitDivision(bounds: CGRect(x: 0, y: 0, width: 382, height: 213),
      isPartiallyOpen: true, divisions: []))
  }

  func testGridTransitionsToSplitAndBackAtTheSameWidth() {
    let grid = grid(width: 669, globe: true)
    let initial = keys(grid).map(\.frame)
    grid.splitDivision = CGRect(x: 304.5, y: 0, width: 60, height: 213)
    grid.layoutIfNeeded()
    XCTAssertEqual(keys(grid).filter { $0.key == .space }.count, 2)
    XCTAssertEqual(keys(grid).filter { $0.key == .character("g") }.count, 2)
    XCTAssertEqual(keys(grid).filter { $0.key == .character("v") }.count, 2)
    for key in keys(grid) {
      XCTAssertTrue(key.frame.maxX <= 304.5 || key.frame.minX >= 364.5)
    }
    grid.splitDivision = nil
    grid.layoutIfNeeded()
    XCTAssertEqual(keys(grid).map(\.frame), initial)
  }

  func testInlineGlobeDevicePolicyOverridesFalseForDuoAndIPad() {
    XCTAssertTrue(KeyboardGlobePolicy.showsInlineGlobe(needsInputModeSwitchKey: false,
      idiom: .phone, modelIdentifier: "iPhone19,4"))
    XCTAssertTrue(KeyboardGlobePolicy.showsInlineGlobe(needsInputModeSwitchKey: false,
      idiom: .pad, modelIdentifier: "iPad"))
    XCTAssertFalse(KeyboardGlobePolicy.showsInlineGlobe(needsInputModeSwitchKey: false,
      idiom: .phone, modelIdentifier: "iPhone18,1"))
    XCTAssertTrue(KeyboardGlobePolicy.showsInlineGlobe(needsInputModeSwitchKey: true,
      idiom: .phone, modelIdentifier: "unknown"))
  }

  private func grid(width: CGFloat = 430,
                    layer: KeyLayer = .letters,
                    globe: Bool = false) -> KeyboardKeyGrid {
    let grid = KeyboardKeyGrid(frame: CGRect(x: 0, y: 0, width: width, height: 400))
    grid.configure(theme: KeyboardTheme.current(for: .light),
                   layer: layer,
                   asciiMode: false,
                   returnKeyLabel: "换行",
                   showsGlobeRow: globe,
                   leftSpaceKey: RimeSpaceSideKey(mode: .character),
                   rightSpaceKey: RimeSpaceSideKey(mode: .auxiliary))
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    return grid
  }

  func testSideKeyChangesRefreshActionsWithoutChangingKeyCount() throws {
    let grid = KeyboardKeyGrid(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
    func configure(left: RimeSpaceSideKey = RimeSpaceSideKey(),
                   right: RimeSpaceSideKey = RimeSpaceSideKey()) {
      grid.configure(theme: KeyboardTheme.current(for: .light), layer: .letters, asciiMode: false,
        returnKeyLabel: "Return", showsGlobeRow: false, leftSpaceKey: left, rightSpaceKey: right)
      grid.layoutIfNeeded()
    }
    configure()
    let originalSpace = try XCTUnwrap(keys(grid).first { $0.key == .space }).frame
    let originalReturn = try XCTUnwrap(keys(grid).first { $0.key == .returnKey }).frame
    XCTAssertEqual(originalReturn.width, 96.4, accuracy: 0.01)
    XCTAssertFalse(keys(grid).contains { if case .auxiliary = $0.key { return true }; return false })
    configure(left: RimeSpaceSideKey(mode: .character, character: ";"),
              right: RimeSpaceSideKey(mode: .auxiliary))
    XCTAssertLessThan(try XCTUnwrap(keys(grid).first { $0.key == .returnKey }).frame.width, originalReturn.width)
    XCTAssertTrue(keys(grid).contains { $0.key == .character(";") })
    XCTAssertTrue(keys(grid).contains { $0.key == .auxiliary(",") })
    configure(left: RimeSpaceSideKey(mode: .auxiliary),
              right: RimeSpaceSideKey(mode: .character, character: "!"))
    let space = try XCTUnwrap(keys(grid).first { $0.key == .space })
    let left = try XCTUnwrap(keys(grid).first { $0.key == .auxiliary(",") })
    let right = try XCTUnwrap(keys(grid).first { $0.key == .character("!") })
    XCTAssertLessThan(left.frame.minX, space.frame.minX)
    XCTAssertGreaterThan(right.frame.minX, space.frame.minX)
    XCTAssertFalse(keys(grid).contains { $0.key == .character(";") })
    configure()
    XCTAssertEqual(try XCTUnwrap(keys(grid).first { $0.key == .space }).frame, originalSpace)
    XCTAssertEqual(try XCTUnwrap(keys(grid).first { $0.key == .returnKey }).frame, originalReturn)
  }

  private func keys(_ grid: KeyboardKeyGrid) -> [KeyButton] {
    grid.subviews.compactMap { $0 as? KeyButton }
  }

  /// Every key is inside the grid, and every key is at least the measured height: a key that overflows
  /// its own view is unreachable no matter what the model says.
  func testEveryKeyIsInsideTheGrid() {
    for layer in [KeyLayer.letters, .numbers, .symbols] {
      let grid = grid(layer: layer)
      let buttons = keys(grid)
      XCTAssertFalse(buttons.isEmpty, "no keys were laid out for \(layer)")
      for button in buttons {
        XCTAssertGreaterThanOrEqual(button.frame.width, 20, "\(layer): a key narrower than 20 pt")
        XCTAssertGreaterThanOrEqual(button.frame.height, KeyboardMetrics.keyHeight - 0.5,
                                    "\(layer): a key shorter than the measured height")
        XCTAssertGreaterThanOrEqual(button.frame.minX, -0.5, "\(layer): a key starts left of the grid")
        XCTAssertLessThanOrEqual(button.frame.maxX, grid.bounds.width + 0.5,
                                 "\(layer): a key ends past the right edge")
      }
    }
  }

  func testBottomRowFitsPhoneWidths() throws {
    for width: CGFloat in [320, 375, 390, 402, 430, 440] {
      for layer in [KeyLayer.letters, .numbers, .symbols] {
        let buttons = keys(grid(width: width, layer: layer))
        let enter = try XCTUnwrap(buttons.first { $0.key == .returnKey })
        let space = try XCTUnwrap(buttons.first { $0.key == .space })
        let comma = try XCTUnwrap(buttons.first {
          $0.key == .character(",") && abs($0.frame.minY - space.frame.minY) < 0.01
        })
        XCTAssertEqual(space.frame.minX - comma.frame.maxX, KeyboardMetrics.keyGap, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(comma.frame.width, 20)
        XCTAssertEqual(enter.frame.maxX, width - KeyboardMetrics.sideMargin, accuracy: 0.01)
        let auxiliary = try XCTUnwrap(buttons.first {
          if case .auxiliary = $0.key { return true }
          return false
        })
        XCTAssertEqual(auxiliary.frame.minX - space.frame.maxX, KeyboardMetrics.keyGap, accuracy: 0.01)
        XCTAssertEqual(enter.frame.minX - auxiliary.frame.maxX, KeyboardMetrics.keyGap, accuracy: 0.01)
        XCTAssertGreaterThan(space.frame.width, enter.frame.width,
                             "space must remain wider than Return after adding punctuation")
      }
    }
  }

  /// Rows are bands: no key overlaps a key in another row, and the rows together are exactly the height
  /// the engine says they are. Two models of the same keyboard disagreeing is the bug this catches.
  func testRowsDoNotOverlapAndTheirUnionIsTheModelHeight() throws {
    let grid = grid()
    let buttons = keys(grid)
    let rows = Dictionary(grouping: buttons) { round($0.frame.minY) }
    XCTAssertEqual(rows.count, 4, "four rows for the letters layer")

    let ordered = rows.keys.sorted()
    for (previous, next) in zip(ordered, ordered.dropFirst()) {
      let previousBottom = try XCTUnwrap(rows[previous]).map(\.frame.maxY).max() ?? 0
      XCTAssertLessThanOrEqual(previousBottom, next + 0.5,
                               "row at \(previous) overlaps the row at \(next)")
    }

    let unionHeight = (ordered.last ?? 0) - (ordered.first ?? 0)
      + (rows[ordered.last ?? 0]?.map(\.frame.height).max() ?? 0)
    XCTAssertEqual(unionHeight, KeyboardKeyGrid.rowsHeight(width: 430, needsGlobeRow: false),
                   accuracy: 0.5,
                   "the laid-out rows and the engine's row model disagree")
  }

  /// Devices needing a switch key keep it in the bottom row without increasing height.
  func testTheGlobeSharesTheBottomRow() {
    let without = KeyboardKeyGrid.rowsHeight(width: 430, needsGlobeRow: false)
    let with = KeyboardKeyGrid.rowsHeight(width: 430, needsGlobeRow: true)
    XCTAssertEqual(with, without,
                   accuracy: 0.5)

    let grid = grid(globe: true)
    let rows = Dictionary(grouping: keys(grid)) { round($0.frame.minY) }
    XCTAssertEqual(rows.count, 4, "the globe shares the bottom control row")
    let globe = keys(grid).first { $0.key == .globe }!
    let space = keys(grid).first { $0.key == .space }!
    XCTAssertEqual(globe.frame.minY, space.frame.minY)
    XCTAssertEqual(globe.frame.height, KeyboardMetrics.keyHeight)
  }

  /// S3 §8: a third-party keyboard that VoiceOver cannot describe is unusable. Every key the grid lays
  /// out carries a label, and the label is never the empty string.
  func testEveryKeyCarriesAnAccessibilityLabel() {
    for layer in [KeyLayer.letters, .numbers, .symbols] {
      for button in keys(grid(layer: layer)) {
        let label = button.accessibilityLabel ?? ""
        XCTAssertFalse(label.trimmingCharacters(in: .whitespaces).isEmpty,
                       "\(layer): a key without an accessibility label")
      }
    }
  }

  /// The style the views use is the engine's measured one: the view layer must not carry a second copy
  /// of the numbers S3 §3 measured.
  func testTheViewMetricsAreTheEnginesMeasuredStyle() {
    XCTAssertEqual(KeyboardMetrics.style, RimeKeyboardStyle.systemAligned)
    XCTAssertEqual(KeyboardMetrics.keyHeight, 45, accuracy: 0.01)
    XCTAssertEqual(KeyboardMetrics.candidateBarHeight, 52, accuracy: 0.01)
    XCTAssertEqual(KeyboardMetrics.keyGap, 6, accuracy: 0.01)
    XCTAssertEqual(KeyboardMetrics.sideMargin, 6.5, accuracy: 0.01)
  }

  /// The frame the extension asks for is the sum of the views stacked inside it: the candidate bar, and the key
  /// grid directly below it. Round 191: the grid was pinned one row gap lower than that, so the two disagreed by
  /// 11 pt — and the system clipped the disagreement off the bottom row. This is the arithmetic half, which runs
  /// without a controller.
  func testTheHeightTheExtensionAsksForIsTheSumOfItsViews() {
    for globe in [false, true] {
      let stack = KeyboardMetrics.candidateBarHeight
        + KeyboardKeyGrid.rowsHeight(width: 430, needsGlobeRow: globe)
        + KeyboardMetrics.keyBottomPadding
      XCTAssertEqual(stack, KeyboardMetrics.totalHeight(needsGlobeRow: globe), accuracy: 0.01,
                     "the bar plus the grid is not what the extension asks for, globe row "
                       + (globe ? "shown" : "hidden"))
    }
  }

  func testExtensionGeometryMatchesTheDeviceReferenceAfterHostInsets() {
    XCTAssertEqual(KeyboardMetrics.totalHeight(needsGlobeRow: false), 270, accuracy: 0.01)
    XCTAssertEqual(KeyboardMetrics.keyBottomPadding, 5)
    let reference = RimeKeyboardLayoutEngine.layout(width: 430, style: KeyboardMetrics.style)
    XCTAssertEqual(reference.rows[0].keys[0].frame.width, 36.3, accuracy: 0.01)
    XCTAssertEqual(KeyboardKeyGrid.rowsHeight(width: 430, needsGlobeRow: false), 213)
  }
}
