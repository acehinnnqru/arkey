import XCTest
import UIKit
import RimeEngine

/// S3 §8's candidate bar, on the simulator: "the candidate bar's items are labelled with their candidate
/// and index". The engine's macOS tests pin the model's labels; this pins what the **buttons** carry
/// after the view has applied that model, which is what VoiceOver actually reads.
final class CandidateBarAccessibilityTests: XCTestCase {
  func testCandidateHitTargetsIncludePaddingInBothPresentations() throws {
    let collapsed = bar(.init(cells: [RimeCandidateCell(index: 0, text: "A")]))
    let expanded = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 430, height: 254))
    expanded.applyContinuation([RimeCandidateItem(text: "A")], startingAt: 0)
    expanded.layoutIfNeeded()
    for view: UIView in [collapsed, expanded] {
      let button = try XCTUnwrap(allButtons(in: view).first { $0.accessibilityLabel == "A" })
      XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
      for point in [CGPoint(x: 1, y: 1),
                    CGPoint(x: button.bounds.maxX - 1, y: button.bounds.maxY - 1)] {
        let target = view.hitTest(button.convert(point, to: view), with: nil)
        XCTAssertTrue(target === button, "Candidate padding must remain tappable")
      }
    }
  }

  func testCandidateTextAndChevronAreVerticallyCentered() throws {
    let view = bar(.init(cells: [RimeCandidateCell(index: 0, text: "你好", comment: "ni hao")]))
    let candidate = try XCTUnwrap(allButtons(in: view).first { $0.attributedTitle(for: .normal) != nil })
    let expand = try XCTUnwrap(allButtons(in: view).first { $0.accessibilityLabel == "展开候选面板" })
    candidate.layoutIfNeeded()
    expand.layoutIfNeeded()
    let label = try XCTUnwrap(candidate.titleLabel)
    let image = try XCTUnwrap(expand.imageView)
    XCTAssertEqual(label.convert(label.bounds, to: view).midY, view.bounds.midY, accuracy: 0.5)
    XCTAssertEqual(image.convert(image.bounds, to: view).midY, view.bounds.midY, accuracy: 0.5)
  }

  func testExpansionCentersFirstCandidateAndKeepsBaseline() throws {
    for width: CGFloat in [320, 430] {
      for word in ["你", "你好", "A longer candidate"] {
        let collapsed = bar(RimeCandidateBarModel(cells: [RimeCandidateCell(index: 0, text: word)]))
        collapsed.frame.size.width = width
        collapsed.layoutIfNeeded()
        let expanded = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: width, height: 254))
        expanded.applyContinuation([word, "B", "Other", "你"].map { RimeCandidateItem(text: $0) }, startingAt: 0)
        expanded.layoutIfNeeded()
        let stripButton = try XCTUnwrap(allButtons(in: collapsed).first { $0.attributedTitle(for: .normal) != nil })
        let gridButton = try XCTUnwrap(allButtons(in: expanded).first { $0.title(for: .normal) == word })
        stripButton.layoutIfNeeded()
        gridButton.superview?.superview?.layoutIfNeeded()
        gridButton.layoutIfNeeded()
        let stripLabel = try XCTUnwrap(stripButton.titleLabel)
        let gridLabel = try XCTUnwrap(gridButton.titleLabel)
        let stripFrame = stripLabel.convert(stripLabel.bounds, to: collapsed)
        let gridFrame = gridLabel.convert(gridLabel.bounds, to: expanded)
        let cellFrame = gridButton.convert(gridButton.bounds, to: expanded)
        // UIKit rounds label frames to device pixels.
        XCTAssertEqual(gridFrame.midX, cellFrame.midX, accuracy: 1 / UIScreen.main.scale, word)
        XCTAssertEqual(gridFrame.minY, stripFrame.minY, accuracy: 0.01, word)
        XCTAssertEqual(gridFrame.height, stripFrame.height, accuracy: 0.01, word)
        let stripInk = try inkBounds(of: stripButton).offsetBy(
          dx: stripButton.convert(.zero, to: collapsed).x, dy: stripButton.convert(.zero, to: collapsed).y)
        let gridInk = try inkBounds(of: gridButton).offsetBy(
          dx: gridButton.convert(.zero, to: expanded).x, dy: gridButton.convert(.zero, to: expanded).y)
        XCTAssertEqual(gridInk.minY, stripInk.minY, accuracy: 1.0 / 3, word)
        XCTAssertEqual(gridInk.height, stripInk.height, accuracy: 1.0 / 3, word)
      }
    }
  }

  private func inkBounds(of button: UIButton) throws -> CGRect {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 3
    let image = UIGraphicsImageRenderer(size: button.bounds.size, format: format).image { renderer in
      UIColor.white.setFill()
      renderer.fill(button.bounds)
      button.layer.render(in: renderer.cgContext)
    }
    let cgImage = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cgImage.width, height: cgImage.height,
      bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    var bounds = CGRect.null
    for y in 0..<cgImage.height {
      for x in 0..<cgImage.width {
        let index = (y * cgImage.width + x) * 4
        if bytes[index] < 100 && bytes[index + 1] < 100 && bytes[index + 2] < 100 {
          bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
      }
    }
    XCTAssertFalse(bounds.isNull)
    return CGRect(x: bounds.minX / 3, y: bounds.minY / 3, width: bounds.width / 3, height: bounds.height / 3)
  }

  private func allButtons(in view: UIView) -> [UIButton] {
    view.subviews.flatMap { subview -> [UIButton] in
      var found = allButtons(in: subview)
      if let button = subview as? UIButton { found.append(button) }
      return found
    }
  }

  private func bar(_ model: RimeCandidateBarModel) -> CandidateBar {
    let bar = CandidateBar(frame: CGRect(x: 0, y: 0, width: 430, height: KeyboardMetrics.candidateBarHeight))
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

  /// The only accessory is the panel expander.
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
    let narrowCount = candidates().count
    XCTAssertLessThan(narrowCount, 9)
    let button = try XCTUnwrap(candidates().first)
    XCTAssertFalse(try XCTUnwrap(button.titleLabel).adjustsFontSizeToFitWidth)
    let font = try XCTUnwrap(button.attributedTitle(for: .normal)?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    XCTAssertEqual(font.pointSize, 20)
    view.frame.size.width = 900
    view.setNeedsLayout()
    view.layoutIfNeeded()
    XCTAssertGreaterThan(candidates().count, narrowCount)
  }

  func testWholeCandidateCellsAreTappableIncludingPadding() throws {
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
        XCTAssertEqual(frame.maxX, view.bounds.width, accuracy: 0.5)
        XCTAssertEqual(frame.width, CandidateBar.accessoryWidth, accuracy: 0.5)
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(scroll.frame.minY, RimeCandidatePanelModel.syllableRowHeight, accuracy: 0.5)
        XCTAssertEqual(scroll.frame.maxX, frame.minX, accuracy: 0.5)
        XCTAssertEqual(scroll.frame.maxY, view.bounds.height, accuracy: 0.5)
        XCTAssertEqual(scroll.frame.height, 270, accuracy: 0.5)
      }
    }
  }

  func testExpandedLongCandidatesWrapAndRemainReachable() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 373))
    view.apply(model: .all((0..<36).map { _ in RimeCandidateItem(text: "这是一个很长的候选词", comment: nil) }))
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UICollectionView }.first)
    XCTAssertEqual(scroll.numberOfItems(inSection: 0), 36)
    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
    var selected: Int?
    view.onSelect = { selected = $0 }
    for index in 0..<36 {
      let path = IndexPath(item: index, section: 0)
      scroll.scrollToItem(at: path, at: .top, animated: false)
      scroll.layoutIfNeeded()
      let cell = try XCTUnwrap(scroll.cellForItem(at: path))
      let button = try XCTUnwrap(allButtons(in: cell).first)
      XCTAssertEqual(button.titleLabel?.font.pointSize, 20)
      XCTAssertEqual(button.titleLabel?.adjustsFontSizeToFitWidth, false)
      XCTAssertLessThanOrEqual(button.frame.maxX, scroll.bounds.width)
      let point = button.convert(CGPoint(x: 1, y: button.bounds.midY), to: view)
      let hit = try XCTUnwrap(view.hitTest(point, with: nil) as? UIButton)
      XCTAssertTrue(hit === button)
      hit.sendActions(for: .touchUpInside)
      XCTAssertEqual(selected, button.tag)
    }
    XCTAssertFalse(try XCTUnwrap(allButtons(in: view).first { $0.accessibilityLabel == "收起候选面板" }).superview!.isHidden)
  }

  func testExpandedMixedShortCandidatesKeepColumnCenters() throws {
    let words = ["你好", "👋", "你会", "你回", "你还", "你和",
                 "霓凰", "倪鸿", "你", "尼", "泥", "逆", "拟"]
    for width: CGFloat in [320, 430] {
      let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: width, height: 265))
      view.applyContinuation(words.map { RimeCandidateItem(text: $0) }, startingAt: 0)
      view.layoutIfNeeded()
      let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UICollectionView }.first)
      let columns = width == 320 ? 5 : 6
      let trackWidth = scroll.bounds.width / CGFloat(columns)
      for index in words.indices {
        let path = IndexPath(item: index, section: 0)
        let frame = try XCTUnwrap(scroll.collectionViewLayout.layoutAttributesForItem(at: path)).frame
        XCTAssertEqual(frame.midX, (CGFloat(index % columns) + 0.5) * trackWidth, accuracy: 0.01)
        XCTAssertEqual(frame.minY, CGFloat(index / columns) * RimeCandidatePanelModel.rowPitch, accuracy: 0.01)
        let button = try XCTUnwrap(scroll.cellForItem(at: path).flatMap { allButtons(in: $0).first })
        button.layoutIfNeeded()
        let label = try XCTUnwrap(button.titleLabel)
        let labelFrame = label.convert(label.bounds, to: button)
        XCTAssertEqual(labelFrame.midX, button.bounds.midX, accuracy: 1 / UIScreen.main.scale)
        let font = try XCTUnwrap(label.font)
        XCTAssertGreaterThanOrEqual(labelFrame.width + 0.5,
          (words[index] as NSString).size(withAttributes: [.font: font]).width)
      }
      // Appending candidates must not redistribute the incomplete final row.
      let lastPath = IndexPath(item: words.count - 1, section: 0)
      let before = try XCTUnwrap(scroll.collectionViewLayout.layoutAttributesForItem(at: lastPath)).frame
      view.applyContinuation((words + ["妮", "泥河"]).map { RimeCandidateItem(text: $0) }, startingAt: 0)
      view.layoutIfNeeded()
      XCTAssertEqual(scroll.collectionViewLayout.layoutAttributesForItem(at: lastPath)?.frame, before)
    }
  }

  func testExpandedUniformCandidatesAlignAndKeepAccessoryRailEmpty() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 430, height: 265))
    view.applyContinuation((0..<40).map { _ in RimeCandidateItem(text: "A") }, startingAt: 0)
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UICollectionView }.first)
    let collapse = try XCTUnwrap(allButtons(in: view).first { $0.accessibilityLabel == "收起候选面板" })
    XCTAssertEqual(scroll.frame.minY, 0)
    XCTAssertEqual(scroll.frame.maxX, collapse.frame.minX, accuracy: 0.01)
    for index in 0..<40 {
      let frame = try XCTUnwrap(scroll.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
      let column = index % 6
      XCTAssertEqual(frame.minX, CGFloat(column) * scroll.bounds.width / 6, accuracy: 0.01)
      XCTAssertLessThanOrEqual(frame.maxX, scroll.bounds.width + 0.01)
    }
    let safePoint = CGPoint(x: collapse.frame.midX, y: view.bounds.height - 10)
    XCTAssertFalse(view.hitTest(safePoint, with: nil) is UIButton)
    scroll.contentOffset.y = 90
    view.layoutIfNeeded()
    XCTAssertFalse(view.hitTest(safePoint, with: nil) is UIButton)
    XCTAssertEqual(collapse.frame.minY, 0)
  }

  func testExpandedMixedCandidatesReflowTheCompleteListWithoutOverlap() throws {
    let words = ["Alpha", "B", "C", "A much longer phrase", "D", "Echo", "F", "Golf"]
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 265))
    view.applyContinuation(words.map { RimeCandidateItem(text: $0) }, startingAt: 0)
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UICollectionView }.first)
    XCTAssertEqual(scroll.numberOfItems(inSection: 0), words.count)
    let frames = try (0..<words.count).map {
      try XCTUnwrap(scroll.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))).frame
    }
    XCTAssertEqual(frames[0].minY, 0)
    XCTAssertGreaterThan(frames[3].minY, frames[0].minY)
    XCTAssertGreaterThan(frames[3].width, frames[1].width)
    for (index, frame) in frames.enumerated() {
      XCTAssertLessThanOrEqual(frame.maxX, scroll.bounds.width + 0.01)
      for other in frames.dropFirst(index + 1) {
        XCTAssertFalse(frame.insetBy(dx: 0.1, dy: 0.1).intersects(other))
      }
    }
    let first = try XCTUnwrap(allButtons(in: scroll).first { $0.tag == 0 })
    XCTAssertEqual(first.title(for: .normal), words[0])
  }

  func testCandidateScrollEdgesDoNotObscureText() throws {
    guard #available(iOS 26.0, *) else { return }
    let collapsed = CandidateBar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
    let expanded = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
    func scrollViews(in view: UIView) -> [UIScrollView] {
      (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    for view in [collapsed, expanded] as [UIView] {
      let scroll = try XCTUnwrap(scrollViews(in: view).first)
      XCTAssertTrue(scroll.topEdgeEffect.isHidden)
      XCTAssertTrue(scroll.bottomEdgeEffect.isHidden)
      XCTAssertTrue(scroll.leftEdgeEffect.isHidden)
      XCTAssertTrue(scroll.rightEdgeEffect.isHidden)
    }
  }

  func testExpandedCandidatesCanScrollWhenDragStartsOnAButton() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
    view.applyContinuation((0..<36).map { RimeCandidateItem(text: "候选词\($0)", comment: nil) },
                           startingAt: 0)
    view.layoutIfNeeded()

    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
    let button = try XCTUnwrap(allButtons(in: scroll).first { !$0.isHidden })
    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
    XCTAssertTrue(scroll.delaysContentTouches,
                  "the scroll view must decide whether a touch is a drag before a cell tracks it")
    XCTAssertTrue(scroll.canCancelContentTouches)
    XCTAssertTrue(scroll.touchesShouldCancel(in: button),
                  "a drag starting on a candidate should scroll instead of tracking the button")
  }

  func testScrollDiagnosticsReportMovementWithoutCandidateContents() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
    view.applyContinuation((0..<200).map { RimeCandidateItem(text: "Private candidate \($0)") }, startingAt: 0)
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UICollectionView }.first)
    var records: [(event: String, milliseconds: Double?, detail: String)] = []
    view.onScrollInteraction = { records.append(($0, $1, $2)) }
    view.scrollViewWillBeginDragging(scroll)
    scroll.contentOffset.y = 120
    view.scrollViewDidEndDragging(scroll, willDecelerate: true)
    view.scrollViewDidEndDecelerating(scroll)
    XCTAssertEqual(records.map(\.event), ["drag.began", "drag.ended", "deceleration.ended"])
    let summary = try XCTUnwrap(records.first { $0.event == "drag.ended" })
    XCTAssertNotNil(summary.milliseconds)
    XCTAssertTrue(summary.detail.contains("offsetDelta=120.0"))
    XCTAssertTrue(summary.detail.contains("maxScrollGapMs="))
    XCTAssertTrue(summary.detail.contains("viewportHeight=300.0"))
    XCTAssertFalse(records.contains { $0.detail.contains("Private candidate") })
  }

  func testLongCandidateListReusesButtonsAndKeepsLastSelectionCorrect() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
    view.applyContinuation((0..<500).map { RimeCandidateItem(text: "候选词\($0)") },
                           startingAt: 0)
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
    XCTAssertLessThan(allButtons(in: scroll).count, 100)
    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)

    let middle = try XCTUnwrap(allButtons(in: scroll).first { !$0.isHidden && $0.tag == 9 })
    for offset: CGFloat in [45, 90, 45, 0] {
      scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
      scroll.layoutIfNeeded()
      XCTAssertTrue(allButtons(in: scroll).first { !$0.isHidden && $0.tag == 9 } === middle,
                    "a candidate still on screen must keep its button while scrolling")
    }

    scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height),
                            animated: false)
    scroll.layoutIfNeeded()
    let last = try XCTUnwrap(allButtons(in: scroll).first {
      !$0.isHidden && $0.tag == 499
    })
    XCTAssertEqual(last.title(for: .normal), "候选词499")
    var selected: Int?
    view.onSelect = { selected = $0 }
    last.sendActions(for: .touchUpInside)
    XCTAssertEqual(selected, 499)
  }

  func testCandidateRefreshKeepsScrollPositionUntilNextExpansion() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
    let candidates = (0..<200).map { RimeCandidateItem(text: "候选词\($0)") }
    view.applyContinuation(candidates, startingAt: 0, resetScroll: true)
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
    scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: false)

    view.applyContinuation(candidates + [RimeCandidateItem(text: "新候选")], startingAt: 0)
    view.layoutIfNeeded()
    XCTAssertEqual(scroll.contentOffset.y, 180, accuracy: 0.5)

    view.applyContinuation(candidates, startingAt: 0, resetScroll: true)
    view.layoutIfNeeded()
    XCTAssertEqual(scroll.contentOffset.y, 0, accuracy: 0.5)

    view.applyContinuation(Array(candidates.prefix(2)), startingAt: 0, resetScroll: true)
    view.layoutIfNeeded()
    let collection = try XCTUnwrap(scroll as? UICollectionView)
    XCTAssertEqual(collection.numberOfItems(inSection: 0), 2)
    XCTAssertEqual(collection.indexPathsForVisibleItems.count, 2)
  }

  func testAppendingCandidatesKeepsVisibleControlsAndScrollPosition() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
    let candidates = (0..<200).map { RimeCandidateItem(text: "Candidate \($0)") }
    view.applyContinuation(Array(candidates.prefix(100)), startingAt: 0, resetScroll: true)
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UICollectionView }.first)
    scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
    scroll.layoutIfNeeded()
    let path = try XCTUnwrap(scroll.indexPathsForVisibleItems.first)
    let original = try XCTUnwrap(scroll.cellForItem(at: path))
    let button = try XCTUnwrap(allButtons(in: original).first)
    let index = button.tag
    view.applyContinuation(candidates, startingAt: 0)
    view.layoutIfNeeded()
    XCTAssertTrue(scroll.cellForItem(at: path) === original)
    XCTAssertEqual(button.tag, index)
    XCTAssertEqual(scroll.contentOffset.y, 180, accuracy: 0.5)
    XCTAssertEqual(scroll.numberOfItems(inSection: 0), 200)
    var selected: Int?
    view.onSelect = { selected = $0 }
    button.sendActions(for: .touchUpInside)
    XCTAssertEqual(selected, index)
    XCTAssertLessThan(allButtons(in: scroll).count, 100)
  }

  func testFirstCandidateLoadAndImmediateContinuationKeepLayoutConsistent() throws {
    // Exercise loading before the panel receives its first nonzero size, and after layout.
    for initialSize in [CGSize.zero, CGSize(width: 430, height: 270)] {
      let view = CandidatePanelView(frame: CGRect(origin: .zero, size: initialSize))
      let candidates = (0..<197).map { RimeCandidateItem(text: "Candidate \($0)") }
      let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UICollectionView }.first)
      view.applyContinuation(Array(candidates.prefix(5)), startingAt: 0)
      view.applyContinuation(Array(candidates.prefix(101)), startingAt: 0)
      view.frame.size = CGSize(width: 430, height: 270)
      view.layoutIfNeeded()
      scroll.setContentOffset(CGPoint(x: 0, y: 90), animated: false)
      view.applyContinuation(candidates, startingAt: 0)
      view.layoutIfNeeded()
      XCTAssertEqual(scroll.contentOffset.y, 90, accuracy: 0.5)
      XCTAssertEqual(scroll.numberOfItems(inSection: 0), candidates.count)
      let attributes = scroll.collectionViewLayout.layoutAttributesForElements(
        in: CGRect(origin: .zero, size: scroll.contentSize)) ?? []
      XCTAssertEqual(Set(attributes.map { $0.indexPath.item }), Set(candidates.indices))
      scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height),
                              animated: false)
      view.layoutIfNeeded()
      let last = try XCTUnwrap(allButtons(in: scroll).first { $0.tag == 196 })
      var selected: Int?
      view.onSelect = { selected = $0 }
      last.sendActions(for: .touchUpInside)
      XCTAssertEqual(selected, 196)
      view.applyContinuation([], startingAt: 0, resetScroll: true)
      view.applyContinuation(Array(candidates.prefix(5)), startingAt: 0)
      view.layoutIfNeeded()
      XCTAssertEqual(scroll.numberOfItems(inSection: 0), 5)
      XCTAssertEqual(scroll.contentOffset.y, 0, accuracy: 0.5)
    }
  }

  func testExpandControlDoesNotParticipateInPagingGestures() throws {
    let view = bar(RimeCandidateBarModel(cells: [RimeCandidateCell(index: 0, text: "Candidate")]))
    let expand = try XCTUnwrap(allButtons(in: view).first { $0.accessibilityLabel == "展开候选面板" })
    var ancestor: UIView? = expand
    while let current = ancestor {
      XCTAssertFalse((current.gestureRecognizers ?? []).contains { $0 is UISwipeGestureRecognizer })
      ancestor = current.superview
    }
    let candidate = try XCTUnwrap(allButtons(in: view).first { $0.tag == 0 && $0 !== expand })
    let scroll = try XCTUnwrap(candidate.superview?.superview as? UIScrollView)
    XCTAssertTrue(scroll.panGestureRecognizer.view === scroll)
    XCTAssertFalse(expand.isDescendant(of: scroll))
  }

  func testFirstCandidateTextOriginStaysFixedAcrossWidthsAndCandidateLists() throws {
    let view = bar(.init(cells: [RimeCandidateCell(index: 0, text: "你")]))
    for width: CGFloat in [320, 430, 900] {
      for text in ["你", "你好", "A much longer candidate"] {
        view.frame.size.width = width
        view.apply(model: .init(cells: [RimeCandidateCell(index: 0, text: text),
                                      RimeCandidateCell(index: 1, text: "Second")]))
        view.layoutIfNeeded()
        let button = try XCTUnwrap(allButtons(in: view).first { $0.attributedTitle(for: .normal) != nil })
        button.layoutIfNeeded()
        let label = try XCTUnwrap(button.titleLabel)
        XCTAssertEqual(label.convert(label.bounds, to: view).minX, 12, accuracy: 0.5)
        XCTAssertEqual(button.contentHorizontalAlignment, .left)
        XCTAssertTrue(button.subviews.allSatisfy { $0 is UILabel || $0 is UIImageView },
                      "candidate cells must not contain separator views")
      }
    }
  }

  func testCollapsedCandidatesScrollAndResetForNewInput() throws {
    let model = RimeCandidateBarModel(cells: (0..<12).map {
      RimeCandidateCell(index: $0, text: "Candidate \($0)")
    })
    let view = bar(model)
    let scroll = try XCTUnwrap(allButtons(in: view).first {
      $0.attributedTitle(for: .normal) != nil
    }?.superview?.superview as? UIScrollView)
    XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
    XCTAssertTrue(scroll.canCancelContentTouches)
    scroll.setContentOffset(CGPoint(x: scroll.contentSize.width - scroll.bounds.width, y: 0), animated: false)
    view.layoutIfNeeded()
    let last = try XCTUnwrap(allButtons(in: scroll).first { !$0.isHidden && $0.tag == 11 })
    XCTAssertTrue(scroll.touchesShouldCancel(in: last))
    var selected: Int?
    view.onSelect = { selected = $0 }
    let point = last.convert(CGPoint(x: last.bounds.midX, y: last.bounds.midY), to: view)
    let hit = try XCTUnwrap(view.hitTest(point, with: nil) as? UIButton)
    hit.sendActions(for: .touchUpInside)
    XCTAssertEqual(selected, 11)
    view.apply(model: model)
    XCTAssertGreaterThan(scroll.contentOffset.x, 0)
    view.apply(model: .init(cells: [RimeCandidateCell(index: 0, text: "New")]))
    view.layoutIfNeeded()
    XCTAssertEqual(scroll.contentOffset.x, 0)
  }

  func testCollapsedListLoadsNearTheEndAndAppendKeepsPosition() throws {
    let cells = (0..<100).map { RimeCandidateCell(index: $0, text: "Candidate \($0)") }
    let view = bar(.init(cells: Array(cells.prefix(50))))
    let scroll = try XCTUnwrap(allButtons(in: view).first {
      $0.attributedTitle(for: .normal) != nil
    }?.superview?.superview as? UIScrollView)
    var requests = 0
    view.onNeedsMoreCandidates = { requests += 1 }
    view.requestMoreCandidatesIfNeeded()
    XCTAssertEqual(requests, 0)
    scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width
    view.layoutIfNeeded()
    XCTAssertGreaterThan(requests, 0)
    let previousOffset = scroll.contentOffset.x
    view.apply(model: .init(cells: cells))
    view.layoutIfNeeded()
    XCTAssertEqual(scroll.contentOffset.x, previousOffset)
    XCTAssertEqual(view.visibleCandidateCount, 0)
    XCTAssertLessThan(allButtons(in: scroll).count, 30)
    scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width
    view.layoutIfNeeded()
    let last = try XCTUnwrap(allButtons(in: scroll).first { !$0.isHidden && $0.tag == 99 })
    var selected: Int?
    view.onSelect = { selected = $0 }
    last.sendActions(for: .touchUpInside)
    XCTAssertEqual(selected, 99)
  }

  func testFiveShortCandidatesRequestContinuationWithoutScrolling() throws {
    for width: CGFloat in [320, 430, 900] {
      let view = CandidateBar(frame: CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics.candidateBarHeight))
      var requests = 0
      view.onNeedsMoreCandidates = { requests += 1 }
      view.applyContinuation(Array(repeating: RimeCandidateItem(text: "你"), count: 5))
      view.layoutIfNeeded()
      XCTAssertGreaterThan(requests, 0, "A short first page must load more before the user drags")
      view.applyContinuation((0..<96).map { RimeCandidateItem(text: "Candidate \($0)") })
      view.layoutIfNeeded()
      let button = try XCTUnwrap(allButtons(in: view).first { $0.attributedTitle(for: .normal) != nil })
      let scroll = try XCTUnwrap(button.superview?.superview as? UIScrollView)
      XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width * 2,
                           "The strip must have content ready for a drag")
      requests = 0
      view.requestMoreCandidatesIfNeeded()
      XCTAssertEqual(requests, 0, "A sufficient buffer must stop automatic loading")
    }
  }

  func testMoreCandidatesAreRequestedOnlyNearTheEnd() throws {
    let view = CandidatePanelView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
    view.applyContinuation((0..<96).map { RimeCandidateItem(text: "Candidate \($0)") },
                           startingAt: 0, resetScroll: true)
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UICollectionView }.first)
    var requests = 0
    view.onNeedsMoreCandidates = { requests += 1 }
    view.requestMoreCandidatesIfNeeded()
    XCTAssertEqual(requests, 0)
    scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height),
                            animated: false)
    XCTAssertGreaterThan(requests, 0)
  }

}
