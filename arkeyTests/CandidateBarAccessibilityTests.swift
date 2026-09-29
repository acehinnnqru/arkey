import XCTest
import UIKit
import RimeEngine

/// S3 §8's candidate bar, on the simulator: "the candidate bar's items are labelled with their candidate
/// and index". The engine's macOS tests pin the model's labels; this pins what the **buttons** carry
/// after the view has applied that model, which is what VoiceOver actually reads.
final class CandidateBarAccessibilityTests: XCTestCase {
  private func allButtons(in view: UIView) -> [UIButton] {
    view.subviews.flatMap { subview -> [UIButton] in
      var found = allButtons(in: subview)
      if let button = subview as? UIButton { found.append(button) }
      return found
    }
  }

  private func bar(_ model: RimeCandidateBarModel) -> CandidateBar {
    let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 430, height: 39.7))
    bar.apply(theme: KeyboardTheme.current(for: .light))
    bar.apply(model: model)
    bar.layoutIfNeeded()
    return bar
  }

  private func visibleButtonCount(_ bar: CandidateBar) -> Int {
    allButtons(in: bar).filter { !$0.isHidden }.count
  }

  private func labels(_ bar: CandidateBar) -> [String] {
    allButtons(in: bar).compactMap { $0.accessibilityLabel }
  }

  /// Every candidate carries its index (when the schema gives select labels) and its text, and a
  /// comment rides in the value: one candidate, one thing for VoiceOver to say.
  func testEveryCandidateIsLabelledWithItsIndexAndText() throws {
    let model = RimeCandidateBarModel(cells: [
      RimeCandidateCell(index: 0, text: "你好", comment: "ni hao", label: "1", isHighlighted: true),
      RimeCandidateCell(index: 1, text: "世界"),
      RimeCandidateCell(index: 2, text: "输入法", label: "3"),
    ])
    let labels = labels(bar(model))
    XCTAssertTrue(labels.contains("1. 你好"), labels.joined(separator: " | "))
    XCTAssertTrue(labels.contains("世界"), labels.joined(separator: " | "))
    XCTAssertTrue(labels.contains("3. 输入法"), labels.joined(separator: " | "))

    let commented = try XCTUnwrap(allButtons(in: bar(model)).first { $0.accessibilityLabel == "1. 你好" })
    XCTAssertEqual(commented.accessibilityValue, "ni hao",
                   "the comment belongs in the value, not glued onto the label")
  }

  /// The chevrons follow the model: a first page has no leading chevron, a last page no trailing one,
  /// and the counts move by exactly one when a page turn becomes available.
  func testThePageChevronsFollowTheModel() {
    let middle = RimeCandidateBarModel(cells: [RimeCandidateCell(index: 0, text: "你")],
                                       pageNumber: 1, isLastPage: false)
    let bothEnds = visibleButtonCount(bar(middle))

    let first = RimeCandidateBarModel(cells: [RimeCandidateCell(index: 0, text: "你")],
                                      pageNumber: 0, isLastPage: false)
    XCTAssertEqual(visibleButtonCount(bar(first)), bothEnds - 1,
                   "a first page must not offer a way back")

    let last = RimeCandidateBarModel(cells: [RimeCandidateCell(index: 0, text: "你")],
                                     pageNumber: 1, isLastPage: true)
    XCTAssertEqual(visibleButtonCount(bar(last)), bothEnds - 1,
                   "a last page must not offer a way forward")
  }

  /// With nothing to show, the bar says what happened rather than showing an empty row: the tracer's
  /// rule is that the candidate slot is the only screen the keyboard owns.
  func testAnEmptyBarShowsItsMessageInsteadOfCells() {
    let boot = RimeCandidateBarModel(cells: [], message: "键盘启动失败：没有可用的配置")
    let bar = bar(boot)
    let texts = bar.subviews.flatMap { view -> [String] in
      var found = view.subviews.compactMap { ($0 as? UILabel)?.text }
      if let label = view as? UILabel, let text = label.text { found.append(text) }
      return found
    }
    XCTAssertTrue(texts.contains("键盘启动失败：没有可用的配置"),
                  "the message is not on screen: " + texts.joined(separator: " | "))
  }
}
