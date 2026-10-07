import CoreGraphics
import Foundation

// MARK: - Cells

/// One candidate as the bar and the panel draw it.
public struct RimeCandidateCell: Sendable, Hashable {
  /// The index passed to the view: page-relative in the bar, global in the expanded panel.
  public let index: Int
  public let text: String
  public let comment: String?
  /// The select key the schema gives this candidate, when it defines labels at all.
  public let label: String?
  public let isHighlighted: Bool

  public init(index: Int, text: String, comment: String? = nil, label: String? = nil,
              isHighlighted: Bool = false) {
    self.index = index
    self.text = text
    self.comment = comment
    self.label = label
    self.isHighlighted = isHighlighted
  }

  public var displayText: String {
    guard let label, !label.isEmpty else { return text }
    return label + " " + text
  }
}

// MARK: - The collapsed bar

/// S3 §7's candidate slot and S4 §6's collapsed bar: one row, the 39.7 pt slot above the keys.
public struct RimeCandidateBarModel: Sendable, Hashable {
  public let cells: [RimeCandidateCell]
  public let pageNumber: Int
  public let isLastPage: Bool
  /// The segmented alternatives iOS shows above the characters. Nil when librime offers no
  /// equivalent — S4 §6 says the row is omitted rather than faked, and this type cannot fake it.
  public let syllableRow: [String]?
  public let height: CGFloat
  /// What the bar says when there is nothing to show: the boot error, or the degraded-mode note.
  /// The tracer's rule is that the bar is the only screen the keyboard owns.
  public let message: String?

  public init(cells: [RimeCandidateCell], pageNumber: Int = 0, isLastPage: Bool = true,
              syllableRow: [String]? = nil, height: CGFloat = 39.7, message: String? = nil) {
    self.cells = cells
    self.pageNumber = pageNumber
    self.isLastPage = isLastPage
    self.syllableRow = syllableRow
    self.height = height
    self.message = message
  }

  public var isEmpty: Bool { cells.isEmpty }

  /// A page turn is offered only where there is somewhere to turn to.
  public var showsLeadingChevron: Bool { pageNumber > 0 }
  public var showsTrailingChevron: Bool { !isLastPage }

  /// The bar for a page of librime's output.
  public static func page(_ page: RimePage?, height: CGFloat = 39.7,
                          syllableRow: [String]? = nil,
                          message: String? = nil) -> RimeCandidateBarModel {
    guard let page else {
      return RimeCandidateBarModel(cells: [], pageNumber: 0, isLastPage: true,
                                   syllableRow: syllableRow, height: height, message: message)
    }
    let cells = page.candidates.enumerated().map { offset, candidate in
      RimeCandidateCell(index: offset,
                        text: candidate.text,
                        comment: candidate.comment,
                        label: page.selectLabels.indices.contains(offset)
                          ? page.selectLabels[offset] : nil,
                        isHighlighted: offset == page.highlightedIndex)
    }
    return RimeCandidateBarModel(cells: cells, pageNumber: page.pageNumber,
                                 isLastPage: page.isLastPage, syllableRow: syllableRow,
                                 height: height, message: cells.isEmpty ? message : nil)
  }

  /// The bar that says something instead of showing candidates.
  public static func message(_ text: String, height: CGFloat = 39.7) -> RimeCandidateBarModel {
    RimeCandidateBarModel(cells: [], height: height, message: text)
  }
}

// MARK: - The expanded panel

/// S4 §6's expanded panel: the keyboard area is replaced, so no key is reachable while it is open.
///
/// Measured (roadmap §S3): the panel's top edge sits 63.3 pt above the normal keyboard top, the
/// syllable row has its own 39.7 pt slot, and the grid below it is 6 × 6 at ≈45 pt row pitch with the
/// selected cell highlighted.
public struct RimeCandidatePanelModel: Sendable, Hashable {
  public static let columns = 6
  public static let rows = 6
  public static let cellsPerPage = columns * rows
  public static let rowPitch: CGFloat = 45
  public static let topOverhang: CGFloat = 63.3
  public static let syllableRowHeight: CGFloat = 39.7

  public let cells: [RimeCandidateCell]
  public let pageNumber: Int
  public let pageCount: Int
  /// The row pitch and the heights are carried so a view cannot invent its own.
  public let rowPitch: CGFloat
  public let syllableRow: [String]?
  public let syllableRowHeight: CGFloat
  public let topOverhang: CGFloat

  /// How many grid rows this page actually fills. The *height* does not follow it: see @B@gridHeight@B@.
  public var occupiedRows: Int { (cells.count + Self.columns - 1) / Self.columns }
  public var isEmpty: Bool { cells.isEmpty }
  public var isFirstPage: Bool { pageNumber == 0 }
  public var isLastPage: Bool { pageNumber >= pageCount - 1 }

  /// The grid is always six rows tall, whatever the last page holds.
  ///
  /// A panel that shrank to its content would change the keyboard's frame when the user scrolls to a
  /// short page — and the frame is what the system animates. The empty cells of a short page are
  /// simply empty.
  public var gridHeight: CGFloat { CGFloat(Self.rows) * rowPitch }

  /// The panel's height, as the sum of its parts — the same rule the keyboard's height follows.
  /// Where the engine has to be before a candidate tapped in the panel can be selected.
  ///
  /// Measured, and it was a defect: the panel numbers the **whole** candidate list (its cells carry that
  /// global index, which is what a tap hands back), while librime's `select_candidate_on_current_page`
  /// numbers the candidates **on the page the engine is showing**. Tapping the tenth cell while the engine
  /// sat on page one therefore asked for a candidate that page did not have. This is the arithmetic between
  /// the two numbering schemes; the caller pages the engine to `page` and selects at `indexOnPage`.
  public static func engineSelection(forGlobalIndex index: Int,
                                     pageNumber: Int,
                                     pageSize: Int) -> (page: Int, indexOnPage: Int)? {
    guard index >= 0, pageSize > 0 else { return nil }
    return (index / pageSize, index % pageSize)
  }

  /// The bottom inset is the keyboard's, because the panel sits in the same place.
  public func height(bottomInset: CGFloat) -> CGFloat {
    topOverhang + syllableRowHeight + gridHeight + bottomInset
  }

  /// A page of the whole candidate list, which is what the panel scrolls through.
  public static func page(_ candidates: [RimeCandidateItem], page: Int,
                          highlightedIndex: Int? = nil,
                          selectLabels: [String] = [],
                          syllableRow: [String]? = nil) -> RimeCandidatePanelModel {
    let pageCount = max(1, (candidates.count + cellsPerPage - 1) / cellsPerPage)
    let clamped = min(max(page, 0), pageCount - 1)
    let start = clamped * cellsPerPage
    let end = min(start + cellsPerPage, candidates.count)
    let cells = (start..<end).map { index -> RimeCandidateCell in
      let candidate = candidates[index]
      let labelIndex = index - start
      return RimeCandidateCell(index: index,
                               text: candidate.text,
                               comment: candidate.comment,
                               label: selectLabels.indices.contains(labelIndex)
                                 ? selectLabels[labelIndex] : nil,
                               isHighlighted: index == highlightedIndex)
    }
    return RimeCandidatePanelModel(cells: cells, pageNumber: clamped, pageCount: pageCount,
                                   rowPitch: rowPitch, syllableRow: syllableRow,
                                   syllableRowHeight: syllableRowHeight, topOverhang: topOverhang)
  }

  /// The whole list in one model, for the tests and for a diagnostics screen that wants everything.
  public static func all(_ candidates: [RimeCandidateItem]) -> RimeCandidatePanelModel {
    page(candidates, page: 0)
  }
}
