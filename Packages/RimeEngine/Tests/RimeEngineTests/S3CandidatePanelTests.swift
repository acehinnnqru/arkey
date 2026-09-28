import XCTest
import CoreGraphics
@testable import RimeEngine

/// S3 §7's candidate slot and S4 §6's expanded panel, as models: paging, labels, highlighting, and
/// the rule that the panel replaces the keyboard rather than floating over it.
final class S3CandidatePanelTests: XCTestCase {
  private func page(candidates: [(String, String?)], highlighted: Int = 0, pageNumber: Int = 0,
                    pageSize: Int = 5, isLastPage: Bool = true,
                    labels: [String] = []) -> RimePage {
    RimePage(candidates: candidates.map { RimeCandidateItem(text: $0.0, comment: $0.1) },
             highlightedIndex: highlighted, pageNumber: pageNumber, pageSize: pageSize,
             isLastPage: isLastPage, selectLabels: labels)
  }

  // MARK: The collapsed bar

  func testTheBarMirrorsThePageItWasGiven() {
    let model = RimeCandidateBarModel.page(page(candidates: [("你好", "ni hao"), ("你", nil)],
                                               highlighted: 0,
                                               labels: ["1", "2"]))
    XCTAssertEqual(model.cells.count, 2)
    XCTAssertEqual(model.cells[0].text, "你好")
    XCTAssertEqual(model.cells[0].comment, "ni hao")
    XCTAssertEqual(model.cells[0].label, "1")
    XCTAssertTrue(model.cells[0].isHighlighted)
    XCTAssertFalse(model.cells[1].isHighlighted)
    XCTAssertEqual(model.cells[0].displayText, "1 你好")
    XCTAssertEqual(model.height, 39.7, "the measured slot")
    XCTAssertNil(model.syllableRow, "librime offers no segmentation here, so the row is omitted")
  }

  func testChevronsAppearOnlyWhereThereIsSomewhereToGo() {
    let first = RimeCandidateBarModel.page(page(candidates: [("a", nil), ("b", nil)],
                                                pageNumber: 0, isLastPage: false))
    XCTAssertFalse(first.showsLeadingChevron, "there is no page before the first")
    XCTAssertTrue(first.showsTrailingChevron)

    let last = RimeCandidateBarModel.page(page(candidates: [("c", nil)],
                                               pageNumber: 3, isLastPage: true))
    XCTAssertTrue(last.showsLeadingChevron)
    XCTAssertFalse(last.showsTrailingChevron)

    let only = RimeCandidateBarModel.page(page(candidates: [("a", nil)]))
    XCTAssertFalse(only.showsLeadingChevron)
    XCTAssertFalse(only.showsTrailingChevron)
  }

  func testAnEmptyBarSaysWhyItIsEmpty() {
    let idle = RimeCandidateBarModel.page(nil)
    XCTAssertTrue(idle.isEmpty)
    XCTAssertNil(idle.message, "an empty slot with nothing to say is just empty")

    let failed = RimeCandidateBarModel.message("Arkey 启动失败：RimeData 缺失")
    XCTAssertTrue(failed.isEmpty)
    XCTAssertEqual(failed.message, "Arkey 启动失败：RimeData 缺失",
                   "the bar is the only screen the keyboard owns (S4 §10)")
    XCTAssertFalse(failed.showsTrailingChevron)
  }

  // MARK: The expanded panel

  func testThePanelPagesTheWholeCandidateList() {
    let candidates = (0..<100).map { RimeCandidateItem(text: "候选\($0)", comment: nil) }
    let first = RimeCandidatePanelModel.page(candidates, page: 0)
    XCTAssertEqual(RimeCandidatePanelModel.cellsPerPage, 36, "6 × 6")
    XCTAssertEqual(first.pageCount, 3, "36 + 36 + 28")
    XCTAssertEqual(first.cells.count, 36)
    XCTAssertEqual(first.cells.first?.index, 0)
    XCTAssertEqual(first.pageNumber, 0)
    XCTAssertTrue(first.isFirstPage)
    XCTAssertFalse(first.isLastPage)
    XCTAssertEqual(first.occupiedRows, 6)
    XCTAssertEqual(first.gridHeight, 270, "6 rows at the 45 pt pitch")

    let third = RimeCandidatePanelModel.page(candidates, page: 2)
    XCTAssertEqual(third.cells.count, 28)
    XCTAssertTrue(third.isLastPage)
    XCTAssertEqual(third.occupiedRows, 5, "the last page is shorter")
    XCTAssertEqual(third.gridHeight, 270,
                   "but the grid keeps its height: a panel that shrank would move the keyboard's frame")

    // A page beyond the end clamps rather than coming back empty.
    let clamped = RimeCandidatePanelModel.page(candidates, page: 99)
    XCTAssertEqual(clamped.pageNumber, 2)
    XCTAssertEqual(clamped.cells.count, 28)
  }

  func testThePanelKeepsGlobalIndicesAndTheHighlight() {
    let candidates = (0..<40).map { RimeCandidateItem(text: "c\($0)", comment: nil) }
    let second = RimeCandidatePanelModel.page(candidates, page: 1, highlightedIndex: 37,
                                              selectLabels: ["1", "2"])
    XCTAssertEqual(second.cells.first?.index, 36, "cells carry librime's own indices")
    XCTAssertEqual(second.cells.first?.label, "1", "labels restart on each page")
    XCTAssertEqual(second.cells[1].label, "2")
    XCTAssertTrue(second.cells[1].isHighlighted, "index 37 is the second cell of page 1")
    XCTAssertFalse(second.cells[0].isHighlighted)
  }

  func testThePanelHeightIsTheSumOfItsMeasuredParts() {
    let candidates = (0..<12).map { RimeCandidateItem(text: "c\($0)", comment: nil) }
    let model = RimeCandidatePanelModel.page(candidates, page: 0)
    XCTAssertEqual(model.topOverhang, 63.3, "the panel's top edge sits above the keyboard's")
    XCTAssertEqual(model.syllableRowHeight, 39.7)
    XCTAssertEqual(model.occupiedRows, 2)
    // 63.3 overhang + 39.7 syllable slot + 6 × 45 grid + the keyboard's own 80.3 bottom inset.
    XCTAssertEqual(model.height(bottomInset: 80.3), 453.3, accuracy: 0.01)

    // An empty page keeps the same height, for the same reason: the panel replaces the keyboard.
    let empty = RimeCandidatePanelModel.page([], page: 0)
    XCTAssertEqual(empty.cells.count, 0)
    XCTAssertEqual(empty.occupiedRows, 0)
    XCTAssertEqual(empty.height(bottomInset: 80.3), 453.3, accuracy: 0.01)
    XCTAssertEqual(empty.pageCount, 1)
  }

  func testThePanelCarriesASyllableRowOnlyWhenOneIsGiven() {
    let candidates = [RimeCandidateItem(text: "你好", comment: nil)]
    XCTAssertNil(RimeCandidatePanelModel.page(candidates, page: 0).syllableRow)
    let withRow = RimeCandidatePanelModel.page(candidates, page: 0,
                                               syllableRow: ["ni", "hao"])
    XCTAssertEqual(withRow.syllableRow, ["ni", "hao"])
    XCTAssertEqual(withRow.height(bottomInset: 80.3),
                   6 * RimeCandidatePanelModel.rowPitch + 39.7 + 63.3 + 80.3, accuracy: 0.01)
  }

  /// S4-AC5/S4 §6: the panel numbers the whole list, the engine numbers the page it is showing. Tapping the
  /// tenth cell while the engine is on page one used to ask for a candidate page one did not have.
  func testATapOnThePanelMapsToTheEnginesOwnPageAndIndex() throws {
    let first = try XCTUnwrap(RimeCandidatePanelModel.engineSelection(forGlobalIndex: 0,
                                                                     pageNumber: 0, pageSize: 5))
    XCTAssertEqual(first.page, 0)
    XCTAssertEqual(first.indexOnPage, 0)

    let tapped = try XCTUnwrap(RimeCandidatePanelModel.engineSelection(forGlobalIndex: 12,
                                                                      pageNumber: 0, pageSize: 5))
    XCTAssertEqual(tapped.page, 2, "the engine has to page there first")
    XCTAssertEqual(tapped.indexOnPage, 2, "and then select by the label on that page")

    XCTAssertNil(RimeCandidatePanelModel.engineSelection(forGlobalIndex: -1, pageNumber: 0, pageSize: 5))
    XCTAssertNil(RimeCandidatePanelModel.engineSelection(forGlobalIndex: 3, pageNumber: 0, pageSize: 0),
                 "a schema that pages zero candidates is not selectable")
  }
}
