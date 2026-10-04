import XCTest
import UIKit
import RimeEngine

/// S6 §2.1's keyboard layer, as it can only be checked on a simulator: the same invariants the engine's
/// macOS tests assert, but measured off the **views that actually lay out**. A frame that is right in
/// the model and wrong in the view is the failure this target exists to catch, and no test on the Mac
/// can see it.
final class KeyboardGeometryTests: XCTestCase {
  private func grid(width: CGFloat = 430,
                    layer: KeyLayer = .letters,
                    globe: Bool = false) -> KeyboardKeyGrid {
    let grid = KeyboardKeyGrid(frame: CGRect(x: 0, y: 0, width: width, height: 400))
    grid.configure(theme: KeyboardTheme.current(for: .light),
                   layer: layer,
                   asciiMode: false,
                   returnKeyLabel: "换行",
                   showsGlobeRow: globe)
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    return grid
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

  /// The globe row is added below the action row, and it does not push the other rows around.
  func testTheGlobeRowOnlyAddsHeight() {
    let without = KeyboardKeyGrid.rowsHeight(width: 430, needsGlobeRow: false)
    let with = KeyboardKeyGrid.rowsHeight(width: 430, needsGlobeRow: true)
    XCTAssertEqual(with - without, KeyboardMetrics.rowGap + KeyboardMetrics.globeRowHeight,
                   accuracy: 0.5)

    let grid = grid(globe: true)
    let rows = Dictionary(grouping: keys(grid)) { round($0.frame.minY) }
    XCTAssertEqual(rows.count, 5, "four rows plus the globe row")
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
      XCTAssertEqual(stack, KeyboardMetrics.totalHeight(needsGlobeRow: globe), accuracy: 0.01,
                     "the bar plus the grid is not what the extension asks for, globe row "
                       + (globe ? "shown" : "hidden"))
    }
  }
}
