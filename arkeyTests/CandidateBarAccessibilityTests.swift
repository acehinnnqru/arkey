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

  /// Paging stays available through swipes; the only accessory is the panel expander.
  func testPagesOnlyShowCandidatesAndTheExpandButton() {
    for (pageNumber, isLastPage) in [(0, false), (1, false), (1, true)] {
      let model = RimeCandidateBarModel(cells: [
        RimeCandidateCell(index: 0, text: "你", isHighlighted: true),
      ], pageNumber: pageNumber, isLastPage: isLastPage)
      let view = bar(model)
      XCTAssertEqual(visibleButtonCount(view), 2)
      XCTAssertFalse(labels(view).contains("上一页"))
      XCTAssertFalse(labels(view).contains("下一页"))
      XCTAssertTrue(labels(view).contains("展开候选面板"))
      let candidate = allButtons(in: view).first { $0.accessibilityLabel == "你" }
      XCTAssertEqual(candidate?.backgroundColor, UIColor.clear)
    }
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
  func testLongCandidatesKeepFontAndAdaptToWidth() throws {
    let view = bar(RimeCandidateBarModel(cells: (0..<9).map {
      RimeCandidateCell(index: $0, text: "这是一个比较长的候选词")
    }))
    func candidates() -> [UIButton] {
      allButtons(in: view).filter { !$0.isHidden && $0.attributedTitle(for: .normal) != nil }
    }
    XCTAssertEqual(candidates().count, 1)
    let button = try XCTUnwrap(candidates().first)
    XCTAssertFalse(try XCTUnwrap(button.titleLabel).adjustsFontSizeToFitWidth)
    let font = try XCTUnwrap(button.attributedTitle(for: .normal)?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    XCTAssertEqual(font.pointSize, 20)
    view.frame.size.width = 900
    view.setNeedsLayout()
    view.layoutIfNeeded()
    XCTAssertGreaterThan(candidates().count, 1)
  }

  func testWholeCandidateCellsAreTappableIncludingSeparatorAndPadding() throws {
    let view = bar(RimeCandidateBarModel(cells: [
      RimeCandidateCell(index: 7, text: "你"),
      RimeCandidateCell(index: 8, text: "这是比较长的词"),
    ]))
    var selected: Int?
    view.onSelect = { selected = $0 }
    for button in allButtons(in: view) where !button.isHidden && button.attributedTitle(for: .normal) != nil {
      for x in [CGFloat(0.5), button.bounds.midX, button.bounds.width - 0.5] {
        let point = button.convert(CGPoint(x: x, y: button.bounds.midY), to: view)
        let hit = try XCTUnwrap(view.hitTest(point, with: nil) as? UIButton)
        XCTAssertTrue(hit === button)
        hit.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, button.tag)
      }
    }
  }

  func testExpandedHeaderStaysAtTopWithCollapseOnTrailingEdge() throws {
    for count in [1, 36, 40] {
      for page in [0, 1] {
        let view = CandidatePanelView(frame: .zero)
        view.apply(model: .page((0..<count).map { _ in
          RimeCandidateItem(text: "测试", comment: nil)
        }, page: page))
        view.frame = CGRect(x: 0, y: 0, width: 430, height: view.height(bottomInset: 0))
        view.layoutIfNeeded()
        let collapse = try XCTUnwrap(allButtons(in: view).first {
          $0.accessibilityLabel == "收起候选面板"
        })
        let frame = collapse.convert(collapse.bounds, to: view)
        XCTAssertEqual(frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(frame.maxX, view.bounds.width - KeyboardMetrics.sideMargin, accuracy: 0.5)
        XCTAssertEqual(frame.width, 32, accuracy: 0.5)
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(scroll.frame.minY, frame.maxY, accuracy: 0.5)
        XCTAssertEqual(scroll.frame.maxY, view.bounds.height, accuracy: 0.5)
        XCTAssertEqual(scroll.frame.height, 270, accuracy: 0.5)
      }
    }
  }

  func testExpandedLongCandidatesWrapAndRemainReachable() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 373))
    view.apply(model: .all((0..<36).map { _ in RimeCandidateItem(text: "这是一个很长的候选词", comment: nil) }))
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
    let buttons = allButtons(in: scroll).filter { !$0.isHidden }
    XCTAssertEqual(buttons.count, 36)
    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
    var selected: Int?
    view.onSelect = { selected = $0 }
    for button in buttons {
      XCTAssertEqual(button.titleLabel?.font.pointSize, 20)
      XCTAssertEqual(button.titleLabel?.adjustsFontSizeToFitWidth, false)
      XCTAssertLessThanOrEqual(button.frame.maxX, scroll.bounds.width)
      scroll.scrollRectToVisible(button.frame, animated: false)
      let point = button.convert(CGPoint(x: 1, y: button.bounds.midY), to: view)
      let hit = try XCTUnwrap(view.hitTest(point, with: nil) as? UIButton)
      XCTAssertTrue(hit === button)
      hit.sendActions(for: .touchUpInside)
      XCTAssertEqual(selected, button.tag)
    }
    XCTAssertFalse(try XCTUnwrap(allButtons(in: view).first { $0.accessibilityLabel == "收起候选面板" }).superview!.isHidden)
  }

  func testExpandedCandidatesCanScrollWhenDragStartsOnAButton() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
    view.applyContinuation((0..<36).map { RimeCandidateItem(text: "候选词\($0)", comment: nil) },
                           startingAt: 0)
    view.layoutIfNeeded()

    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
    let button = try XCTUnwrap(allButtons(in: scroll).first { !$0.isHidden })
    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
    XCTAssertTrue(scroll.canCancelContentTouches)
    XCTAssertTrue(scroll.touchesShouldCancel(in: button),
                  "a drag starting on a candidate should scroll instead of tracking the button")
  }

  func testLongCandidateListReusesButtonsAndKeepsLastSelectionCorrect() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
    view.applyContinuation((0..<500).map { RimeCandidateItem(text: "候选词\($0)") },
                           startingAt: 0)
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
    XCTAssertLessThan(allButtons(in: scroll).count, 100)
    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)

    scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height),
                            animated: false)
    let last = try XCTUnwrap(allButtons(in: scroll).first {
      !$0.isHidden && $0.tag == 499
    })
    XCTAssertEqual(last.title(for: .normal), "候选词499")
    var selected: Int?
    view.onSelect = { selected = $0 }
    last.sendActions(for: .touchUpInside)
    XCTAssertEqual(selected, 499)
  }

}
