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
    button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
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

/// Natural-width rows; UIKit owns cell reuse and the complete scrolling lifecycle.
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
    var y: CGFloat = 0
    var index = 0
    while index < widths.count {
      let start = index
      var used: CGFloat = 0
      while index < widths.count && index - start < RimeCandidatePanelModel.columns {
        let width = min(available, widths[index])
        if index > start && used + width > available { break }
        used += width
        index += 1
      }
      let count = index - start
      let isUniform = widths[start..<index].allSatisfy { $0 == widths[start] }
      let capacity = min(RimeCandidatePanelModel.columns, max(1, Int(available / widths[start])))
      let extra = isUniform ? max(0, available / CGFloat(capacity) - widths[start])
        : (index < widths.count ? (available - used) / CGFloat(count) : 0)
      var x: CGFloat = 0
      for itemIndex in start..<index {
        let width = min(available, widths[itemIndex]) + extra
        let item = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: itemIndex, section: 0))
        item.frame = CGRect(x: x, y: y, width: width, height: rowPitch)
        attributes.append(item)
        x += width
      }
      y += rowPitch
    }
    contentSize = CGSize(width: available, height: y)
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

/// Expanded candidates wrap at their natural text width and scroll within the keyboard.
final class CandidatePanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
  /// A cell was tapped: the argument is librime's own candidate index, not the cell's position.
  var onSelect: ((Int) -> Void)?
  var onCollapse: (() -> Void)?
  /// Page the grid. Never commits (S3 §5).
  var onPage: ((Bool) -> Void)?
  var onNeedsMoreCandidates: (() -> Void)?
  #if DEBUG
  var onScroll: ((CGFloat) -> Void)?
  #endif

  private let syllableRow = UIStackView()
  private let syllables = UILabel()
  private let headerSpacer = UIView()
  private let leadingButton = UIButton(type: .system)
  private let trailingButton = UIButton(type: .system)
  private let collapseButton = UIButton(type: .system)
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
    collapseButton.imageEdgeInsets = UIEdgeInsets(top: 2 * KeyboardMetrics.candidateTextOffset,
                                                left: 0, bottom: 0, right: 0)
    leadingButton.accessibilityLabel = "上一页"
    trailingButton.accessibilityLabel = "下一页"
    collapseButton.accessibilityLabel = "收起候选面板"
    leadingButton.addTarget(self, action: #selector(handleLeading), for: .touchUpInside)
    trailingButton.addTarget(self, action: #selector(handleTrailing), for: .touchUpInside)
    collapseButton.addTarget(self, action: #selector(handleCollapse), for: .touchUpInside)

    gridStack.translatesAutoresizingMaskIntoConstraints = false
    gridStack.accessibilityIdentifier = "candidate-scroll"
    gridStack.alwaysBounceVertical = true
    gridStack.delaysContentTouches = true
    gridStack.canCancelContentTouches = true
    gridStack.delegate = self
    gridStack.dataSource = self
    gridStack.backgroundColor = .clear
    gridStack.contentInsetAdjustmentBehavior = .never
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

  private func replaceEntries(_ updated: [Entry], resetScroll: Bool) {
    let oldCount = entries.count
    let appending = !resetScroll && candidateLayout.rowPitch == rowPitch
      && updated.count >= oldCount && updated.prefix(oldCount).elementsEqual(entries)
    guard resetScroll || updated != entries else { return }
    let newWidths = (appending ? Array(updated.dropFirst(oldCount)) : updated).map { entry in
      let measured = (entry.text as NSString).size(withAttributes: [.font: candidateFont]).width
      return max(44, ceil(measured) + 12)
    }
    // Complete the old layout before changing the data source for inserted items.
    gridStack.layoutIfNeeded()
    entries = updated
    candidateLayout.rowPitch = rowPitch
    if appending {
      candidateLayout.widths.append(contentsOf: newWidths)
      UIView.performWithoutAnimation {
        gridStack.performBatchUpdates {
          candidateLayout.invalidateLayout()
          gridStack.insertItems(at: (oldCount..<updated.count).map { IndexPath(item: $0, section: 0) })
        }
      }
    } else {
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
    let isAnchor = indexPath.item == 0
    button.contentHorizontalAlignment = isAnchor ? .left : .center
    button.contentEdgeInsets = UIEdgeInsets(
      top: 0, left: isAnchor ? KeyboardMetrics.candidateTextLeading - KeyboardMetrics.sideMargin : 6,
      bottom: 0, right: 6)
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
    #if DEBUG
    onScroll?(scrollView.contentOffset.y)
    #endif
    requestMoreCandidatesIfNeeded()
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
