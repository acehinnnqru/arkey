import UIKit
import RimeEngine

/// Keep a drag available to the scroll view even when it starts over a candidate control.
private final class CandidateScrollView: UICollectionView {
  override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

private final class CandidateCollectionCell: UICollectionViewCell {
  let button = UIButton(type: .custom)

  override init(frame: CGRect) {
    super.init(frame: frame)
    button.titleLabel?.font = .systemFont(ofSize: 20)
    button.titleLabel?.lineBreakMode = .byTruncatingTail
    button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
    button.clipsToBounds = true
    button.layer.cornerRadius = 8
    button.layer.cornerCurve = .continuous
    button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    button.frame = contentView.bounds
    contentView.addSubview(button)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func layoutSubviews() {
    // The first row keeps the collapsed strip's text baseline; later rows only add row pitch.
    button.titleEdgeInsets = UIEdgeInsets(
      top: 2 * (KeyboardMetrics.candidateTextCenterY - bounds.height / 2),
      left: 0, bottom: 0, right: 0)
    super.layoutSubviews()
  }
}

/// Fixed column tracks keep mixed candidate lengths aligned across rows.
private final class CandidateCollectionLayout: UICollectionViewLayout {
  var widths: [CGFloat] = []
  var rowPitch: CGFloat = RimeCandidatePanelModel.rowPitch
  private var attributes: [UICollectionViewLayoutAttributes] = []
  private var contentSize = CGSize.zero
  private var measuredWidth: CGFloat = -1
  private var needsMeasurement = true

  override func invalidateLayout() {
    needsMeasurement = true
    super.invalidateLayout()
  }

  override func prepare() {
    super.prepare()
    guard let collectionView, collectionView.bounds.width > 0 else { return }
    let available = collectionView.bounds.width
    guard needsMeasurement || measuredWidth != available else { return }
    measuredWidth = available
    needsMeasurement = false
    attributes.removeAll(keepingCapacity: true)
    // Narrow keyboards use fewer tracks so each candidate retains a 44-point touch target.
    let columns = min(RimeCandidatePanelModel.columns, max(1, Int(available / 44)))
    let columnWidth = available / CGFloat(columns)
    var row = 0
    var column = 0
    for (index, width) in widths.enumerated() {
      // Longer phrases occupy whole tracks, preserving the same grid for following rows.
      let span = min(columns, max(1, Int(ceil(min(available, width) / columnWidth))))
      if column + span > columns {
        row += 1
        column = 0
      }
      let item = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
      item.frame = CGRect(x: CGFloat(column) * columnWidth, y: CGFloat(row) * rowPitch,
                          width: CGFloat(span) * columnWidth, height: rowPitch)
      attributes.append(item)
      column += span
    }
    contentSize = CGSize(width: available, height: widths.isEmpty ? 0 : CGFloat(row + 1) * rowPitch)
  }

  override var collectionViewContentSize: CGSize { contentSize }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
    attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    var low = 0
    var high = attributes.count
    while low < high {
      let middle = (low + high) / 2
      if attributes[middle].frame.maxY < rect.minY { low = middle + 1 }
      else { high = middle }
    }
    var visible: [UICollectionViewLayoutAttributes] = []
    for item in attributes[low...] {
      if item.frame.minY > rect.maxY { break }
      if item.frame.intersects(rect) { visible.append(item) }
    }
    return visible
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    newBounds.width != measuredWidth
  }
}

/// Expanded candidates use up to six aligned columns and scroll within the keyboard.
final class CandidatePanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
  func refreshLocalizedLabels() {
    leadingButton.accessibilityLabel = RimeLocalization.text("Previous page")
    trailingButton.accessibilityLabel = RimeLocalization.text("Next page")
    collapseButton.accessibilityLabel = RimeLocalization.text("Collapse candidates")
  }

  /// A cell was tapped: the argument is librime's own candidate index, not the cell's position.
  var onSelect: ((Int) -> Void)?
  var onCollapse: (() -> Void)?
  var onCollapseInteraction: ((String, TimeInterval?) -> Void)? {
    didSet { collapseButton.onInteraction = onCollapseInteraction }
  }
  /// Page the grid. Never commits (S3 §5).
  var onPage: ((Bool) -> Void)?
  var onNeedsMoreCandidates: (() -> Void)?
  /// Touch/scroll metadata only; candidate contents never enter the diagnostic payload.
  var onScrollInteraction: ((String, Double?, String) -> Void)?
  #if DEBUG
  var onScroll: ((CGFloat) -> Void)?
  #endif

  private let syllableRow = UIStackView()
  private let syllables = UILabel()
  private let headerSpacer = UIView()
  private let leadingButton = UIButton(type: .system)
  private let trailingButton = UIButton(type: .system)
  private let collapseButton = CandidateAccessoryButton(type: .system)
  private let candidateLayout = CandidateCollectionLayout()
  private lazy var gridStack = CandidateScrollView(frame: .zero, collectionViewLayout: candidateLayout)
  private let loadingIndicator = UIActivityIndicatorView(style: .medium)
  private var rowPitch = RimeCandidatePanelModel.rowPitch
  private struct Entry: Equatable {
    let index: Int
    let text: String
    let comment: String?
    let label: String?
    let isHighlighted: Bool
  }
  private var entries: [Entry] = []
  private let candidateFont = UIFont.systemFont(ofSize: 20)
  private var theme = KeyboardTheme.current(for: .default)

  private var gridHeight: CGFloat = CGFloat(RimeCandidatePanelModel.rows)
    * RimeCandidatePanelModel.rowPitch
  private var syllableHeight: CGFloat = RimeCandidatePanelModel.syllableRowHeight
  private var showsSyllables = false
  private var headerHeightConstraint: NSLayoutConstraint!
  private var lastScrollHitTimestamp: TimeInterval?
  private var dragStartedAt: TimeInterval?
  private var lastDragSampleAt: TimeInterval = 0
  private var dragStartOffset: CGFloat = 0
  private var dragSamples = 0
  private var maximumDragGap: TimeInterval = 0

  override init(frame: CGRect) {
    super.init(frame: frame)

    syllableRow.axis = .horizontal
    syllableRow.alignment = .fill
    syllableRow.distribution = .fill
    syllableRow.spacing = 4
    syllableRow.translatesAutoresizingMaskIntoConstraints = false
    syllableRow.addArrangedSubview(leadingButton)
    syllableRow.addArrangedSubview(syllables)
    syllableRow.addArrangedSubview(headerSpacer)
    syllableRow.addArrangedSubview(trailingButton)
    addSubview(syllableRow)
    collapseButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(collapseButton)

    headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    syllables.font = .systemFont(ofSize: 17)
    syllables.textAlignment = .center
    syllables.lineBreakMode = .byTruncatingMiddle
    leadingButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    trailingButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
    collapseButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
    collapseButton.accessibilityIdentifier = "candidate-collapse"
    collapseButton.imageEdgeInsets = UIEdgeInsets(top: 2 * KeyboardMetrics.candidateTextOffset,
                                                left: 0, bottom: 0, right: 0)
    refreshLocalizedLabels()
    leadingButton.addTarget(self, action: #selector(handleLeading), for: .touchUpInside)
    trailingButton.addTarget(self, action: #selector(handleTrailing), for: .touchUpInside)
    collapseButton.addTarget(self, action: #selector(handleCollapse), for: .touchUpInside)

    gridStack.translatesAutoresizingMaskIntoConstraints = false
    gridStack.accessibilityIdentifier = "candidate-scroll"
    gridStack.alwaysBounceVertical = true
    // Let the pan recognizer distinguish a drag before a candidate button starts tracking.
    gridStack.delaysContentTouches = true
    gridStack.canCancelContentTouches = true
    gridStack.delegate = self
    gridStack.dataSource = self
    gridStack.backgroundColor = .clear
    gridStack.contentInsetAdjustmentBehavior = .never
    if #available(iOS 26.0, *) {
      // Keep the system's scroll-edge blur from obscuring candidate rows.
      gridStack.topEdgeEffect.isHidden = true
      gridStack.bottomEdgeEffect.isHidden = true
      gridStack.leftEdgeEffect.isHidden = true
      gridStack.rightEdgeEffect.isHidden = true
    }
    gridStack.register(CandidateCollectionCell.self, forCellWithReuseIdentifier: "candidate")
    addSubview(gridStack)
    loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
    loadingIndicator.hidesWhenStopped = true
    addSubview(loadingIndicator)

    headerHeightConstraint = syllableRow.heightAnchor.constraint(equalToConstant: syllableHeight)
    NSLayoutConstraint.activate([
      syllableRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: KeyboardMetrics.sideMargin),
      syllableRow.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor),
      syllableRow.topAnchor.constraint(equalTo: topAnchor),
      headerHeightConstraint,
      leadingButton.widthAnchor.constraint(equalToConstant: 32),
      trailingButton.widthAnchor.constraint(equalToConstant: 32),
      collapseButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      collapseButton.topAnchor.constraint(equalTo: topAnchor),
      collapseButton.widthAnchor.constraint(equalToConstant: CandidateBar.accessoryWidth),
      collapseButton.heightAnchor.constraint(equalToConstant: KeyboardMetrics.candidateBarHeight),
      gridStack.leadingAnchor.constraint(equalTo: leadingAnchor,
                                         constant: KeyboardMetrics.sideMargin),
      gridStack.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor),
      gridStack.topAnchor.constraint(equalTo: syllableRow.bottomAnchor),
      gridStack.bottomAnchor.constraint(equalTo: bottomAnchor),
      loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
      loadingIndicator.centerYAnchor.constraint(equalTo: gridStack.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// Only the header and candidate rows occupy space inside the extension.
  /// The system owns the globe and home-indicator strip below it.
  func height(bottomInset: CGFloat) -> CGFloat {
    syllableHeight + gridHeight + bottomInset
  }

  func apply(theme: KeyboardTheme) {
    self.theme = theme
    backgroundColor = .clear
    isOpaque = false
    syllables.textColor = theme.candidateText
    for button in [leadingButton, trailingButton, collapseButton] {
      button.tintColor = theme.candidateText.withAlphaComponent(0.6)
    }
    for case let cell as CandidateCollectionCell in gridStack.visibleCells {
      cell.button.setTitleColor(theme.candidateText, for: .normal)
      if let index = gridStack.indexPath(for: cell)?.item, entries.indices.contains(index) {
        cell.button.backgroundColor = entries[index].isHighlighted ? theme.candidatePanelHighlightFill : .clear
      }
    }
  }

  func apply(model: RimeCandidatePanelModel) {
    loadingIndicator.stopAnimating()
    syllableRow.isHidden = false
    headerHeightConstraint.constant = model.syllableRowHeight
    showsSyllables = !(model.syllableRow ?? []).isEmpty
    syllableHeight = model.syllableRowHeight
    rowPitch = model.rowPitch
    gridHeight = model.gridHeight
    headerSpacer.isHidden = showsSyllables
    syllables.isHidden = !showsSyllables
    syllables.text = (model.syllableRow ?? []).joined(separator: " ")
    leadingButton.isHidden = model.isFirstPage
    trailingButton.isHidden = model.isLastPage

    let entries = model.cells.map {
      Entry(index: $0.index, text: $0.text, comment: $0.comment,
            label: $0.label, isHighlighted: $0.isHighlighted)
    }
    replaceEntries(entries, resetScroll: true)
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  /// Reflow the complete candidate list, including its first row, beside the reserved accessory rail.
  func applyContinuation(_ candidates: [RimeCandidateItem], startingAt start: Int,
                         resetScroll: Bool = false) {
    loadingIndicator.stopAnimating()
    syllableRow.isHidden = true
    headerHeightConstraint.constant = 0
    let entries = candidates.dropFirst(min(start, candidates.count)).enumerated().map { offset, item in
      Entry(index: start + offset, text: item.text, comment: item.comment,
            label: nil, isHighlighted: false)
    }
    replaceEntries(entries, resetScroll: resetScroll)
    setNeedsLayout()
  }

  func setLoading(_ loading: Bool) {
    if loading { loadingIndicator.startAnimating() }
    else { loadingIndicator.stopAnimating() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gridStack.layoutIfNeeded()
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let target = super.hitTest(point, with: event)
    if !isHidden, let event, event.type == .touches,
       event.timestamp != lastScrollHitTimestamp, gridStack.frame.contains(point) {
      lastScrollHitTimestamp = event.timestamp
      let role = target === gridStack ? "scroll" : (target?.isDescendant(of: gridStack) == true ? "cell" : "other")
      let delay = max(0, ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
      onScrollInteraction?("hit", nil,
        "target=\(role) deliveryMs=\(String(format: "%.2f", delay)) " + scrollDiagnosticState)
    }
    return target
  }

  private var scrollDiagnosticState: String {
    "enabled=\(gridStack.isScrollEnabled) interactive=\(gridStack.isUserInteractionEnabled)"
      + " tracking=\(gridStack.isTracking) dragging=\(gridStack.isDragging) decelerating=\(gridStack.isDecelerating)"
      + " panState=\(gridStack.panGestureRecognizer.state.rawValue) uncommittedUpdates=\(gridStack.hasUncommittedUpdates)"
      + " offsetY=\(String(format: "%.1f", gridStack.contentOffset.y))"
      + " contentHeight=\(String(format: "%.1f", gridStack.contentSize.height))"
      + " viewportHeight=\(String(format: "%.1f", gridStack.bounds.height))"
  }

  private func replaceEntries(_ updated: [Entry], resetScroll: Bool) {
    let oldCount = entries.count
    let appending = oldCount > 0 && !resetScroll && candidateLayout.rowPitch == rowPitch
      && updated.count >= oldCount && updated.prefix(oldCount).elementsEqual(entries)
    guard resetScroll || updated != entries else { return }
    let newWidths = (appending ? Array(updated.dropFirst(oldCount)) : updated).map { entry in
      let measured = (entry.text as NSString).size(withAttributes: [.font: candidateFont]).width
      return max(44, ceil(measured) + 4)
    }
    // Complete the old layout before changing the data source for inserted items.
    gridStack.layoutIfNeeded()
    if appending {
      UIView.performWithoutAnimation {
        gridStack.performBatchUpdates {
          // UIKit must capture the old item count and layout before either changes.
          entries = updated
          candidateLayout.widths.append(contentsOf: newWidths)
          candidateLayout.invalidateLayout()
          gridStack.insertItems(at: (oldCount..<updated.count).map { IndexPath(item: $0, section: 0) })
        }
      }
    } else {
      entries = updated
      candidateLayout.rowPitch = rowPitch
      candidateLayout.widths = newWidths
      candidateLayout.invalidateLayout()
      gridStack.reloadData()
      if resetScroll { gridStack.setContentOffset(.zero, animated: false) }
    }
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    entries.count
  }

  func collectionView(_ collectionView: UICollectionView,
                      cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "candidate", for: indexPath)
      as! CandidateCollectionCell
    let entry = entries[indexPath.item]
    let button = cell.button
    button.contentHorizontalAlignment = .center
    button.tag = entry.index
    button.accessibilityLabel = entry.label.map { $0 + ". " + entry.text } ?? entry.text
    button.accessibilityValue = entry.comment
    button.setTitle(entry.text, for: .normal)
    button.setTitleColor(theme.candidateText, for: .normal)
    button.backgroundColor = entry.isHighlighted ? theme.candidatePanelHighlightFill : .clear
    button.removeTarget(self, action: #selector(handleCell(_:)), for: .touchUpInside)
    button.addTarget(self, action: #selector(handleCell(_:)), for: .touchUpInside)
    return cell
  }

  func requestMoreCandidatesIfNeeded() {
    guard gridStack.bounds.height > 0,
          gridStack.contentSize.height - gridStack.bounds.maxY < gridStack.bounds.height * 2 else { return }
    onNeedsMoreCandidates?()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if dragStartedAt != nil {
      let now = ProcessInfo.processInfo.systemUptime
      maximumDragGap = max(maximumDragGap, now - lastDragSampleAt)
      lastDragSampleAt = now
      dragSamples += 1
    }
    #if DEBUG
    onScroll?(scrollView.contentOffset.y)
    #endif
    requestMoreCandidatesIfNeeded()
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    let now = ProcessInfo.processInfo.systemUptime
    dragStartedAt = now
    lastDragSampleAt = now
    dragStartOffset = scrollView.contentOffset.y
    dragSamples = 0
    maximumDragGap = 0
    onScrollInteraction?("drag.began", nil, scrollDiagnosticState)
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    guard let start = dragStartedAt else { return }
    let now = ProcessInfo.processInfo.systemUptime
    maximumDragGap = max(maximumDragGap, now - lastDragSampleAt)
    let translation = scrollView.panGestureRecognizer.translation(in: scrollView).y
    onScrollInteraction?("drag.ended", (now - start) * 1000,
      "samples=\(dragSamples) maxScrollGapMs=\(String(format: "%.2f", maximumDragGap * 1000))"
        + " translationY=\(String(format: "%.1f", translation))"
        + " offsetDelta=\(String(format: "%.1f", scrollView.contentOffset.y - dragStartOffset))"
        + " willDecelerate=\(decelerate) " + scrollDiagnosticState)
    dragStartedAt = nil
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    onScrollInteraction?("deceleration.ended", nil, scrollDiagnosticState)
  }

  @objc private func handleCell(_ sender: UIButton) {
    onSelect?(sender.tag)
  }

  @objc private func handleLeading() {
    onPage?(true)
  }

  @objc private func handleTrailing() {
    onPage?(false)
  }

  @objc private func handleCollapse() {
    onCollapse?()
  }
}
