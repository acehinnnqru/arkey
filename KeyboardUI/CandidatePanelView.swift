import UIKit
import RimeEngine

/// Keep a drag available to the scroll view even when it starts over a candidate control.
private final class CandidateScrollView: UIScrollView {
  override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// Expanded candidates wrap at their natural text width and scroll within the keyboard.
final class CandidatePanelView: UIView, UIScrollViewDelegate {
  /// A cell was tapped: the argument is librime's own candidate index, not the cell's position.
  var onSelect: ((Int) -> Void)?
  var onCollapse: (() -> Void)?
  /// Page the grid. Never commits (S3 §5).
  var onPage: ((Bool) -> Void)?
  #if DEBUG
  var onScroll: ((CGFloat) -> Void)?
  #endif

  private let syllableRow = UIStackView()
  private let syllables = UILabel()
  private let headerSpacer = UIView()
  private let leadingButton = UIButton(type: .system)
  private let trailingButton = UIButton(type: .system)
  private let collapseButton = UIButton(type: .system)
  private let gridStack = CandidateScrollView()
  private let loadingIndicator = UIActivityIndicatorView(style: .medium)
  private var rowPitch = RimeCandidatePanelModel.rowPitch
  private var cellButtons: [UIButton] = []
  private struct Entry {
    let index: Int
    let text: String
    let comment: String?
    let label: String?
    let isHighlighted: Bool
  }
  private var entries: [Entry] = []
  private var cellFrames: [CGRect] = []
  private var displayedIndices: [Int] = []
  private var measuredWidth: CGFloat = 0
  private var needsCellLayout = true
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
    syllableRow.addArrangedSubview(collapseButton)
    addSubview(syllableRow)

    headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    syllables.font = .systemFont(ofSize: 17)
    syllables.textAlignment = .center
    syllables.lineBreakMode = .byTruncatingMiddle
    leadingButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    trailingButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
    collapseButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
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
    addSubview(gridStack)
    loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
    loadingIndicator.hidesWhenStopped = true
    addSubview(loadingIndicator)

    headerHeightConstraint = syllableRow.heightAnchor.constraint(equalToConstant: syllableHeight)
    NSLayoutConstraint.activate([
      syllableRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: KeyboardMetrics.sideMargin),
      syllableRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -KeyboardMetrics.sideMargin),
      syllableRow.topAnchor.constraint(equalTo: topAnchor),
      headerHeightConstraint,
      leadingButton.widthAnchor.constraint(equalToConstant: 32),
      trailingButton.widthAnchor.constraint(equalToConstant: 32),
      collapseButton.widthAnchor.constraint(equalToConstant: 32),
      gridStack.leadingAnchor.constraint(equalTo: leadingAnchor,
                                         constant: KeyboardMetrics.sideMargin),
      gridStack.trailingAnchor.constraint(equalTo: trailingAnchor,
                                          constant: -KeyboardMetrics.sideMargin),
      gridStack.topAnchor.constraint(equalTo: syllableRow.bottomAnchor),
      gridStack.bottomAnchor.constraint(equalTo: bottomAnchor),
      loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
      loadingIndicator.centerYAnchor.constraint(equalTo: gridStack.centerYAnchor),
    ])
  }

  private func ensureCells(_ count: Int) {
    while cellButtons.count < count {
      let button = UIButton(type: .custom)
      button.titleLabel?.font = .systemFont(ofSize: 20)
      button.titleLabel?.adjustsFontSizeToFitWidth = false
      button.titleLabel?.lineBreakMode = .byTruncatingTail
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
      button.clipsToBounds = true
      button.layer.cornerRadius = 8
      button.layer.cornerCurve = .continuous
      button.setTitleColor(theme.candidateText, for: .normal)
      button.addTarget(self, action: #selector(handleCell(_:)), for: .touchUpInside)
      gridStack.addSubview(button)
      cellButtons.append(button)
      displayedIndices.append(-1)
    }
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
    for button in cellButtons {
      button.setTitleColor(theme.candidateText, for: .normal)
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

    entries = model.cells.map {
      Entry(index: $0.index, text: $0.text, comment: $0.comment,
            label: $0.label, isHighlighted: $0.isHighlighted)
    }
    needsCellLayout = true
    gridStack.setContentOffset(.zero, animated: false)
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  /// The collapsed candidate row stays in place; this view draws only the rows below it.
  func applyContinuation(_ candidates: [RimeCandidateItem], startingAt start: Int,
                         resetScroll: Bool = false) {
    loadingIndicator.stopAnimating()
    syllableRow.isHidden = true
    headerHeightConstraint.constant = 0
    entries = candidates.dropFirst(min(start, candidates.count)).enumerated().map { offset, item in
      Entry(index: start + offset, text: item.text, comment: item.comment,
            label: nil, isHighlighted: false)
    }
    needsCellLayout = true
    if resetScroll { gridStack.setContentOffset(.zero, animated: false) }
    setNeedsLayout()
  }

  func setLoading(_ loading: Bool) {
    if loading { loadingIndicator.startAnimating() }
    else { loadingIndicator.stopAnimating() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let available = gridStack.bounds.width
    guard available > 0 else { return }
    if needsCellLayout || abs(available - measuredWidth) > 0.5 {
      measureCells(width: available)
    }
    updateVisibleCells()
  }

  private func measureCells(width available: CGFloat) {
    measuredWidth = available
    needsCellLayout = false
    cellFrames.removeAll(keepingCapacity: true)
    cellFrames.reserveCapacity(entries.count)
    var x: CGFloat = 0
    var y: CGFloat = 0
    for entry in entries {
      let measured = (entry.text as NSString).size(withAttributes: [.font: candidateFont]).width
      let width = min(available, max(44, ceil(measured) + 24))
      if x > 0 && x + width > available {
        x = 0
        y += rowPitch
      }
      cellFrames.append(CGRect(x: x, y: y, width: width, height: rowPitch))
      x += width
    }
    for button in cellButtons { button.isHidden = true }
    displayedIndices = Array(repeating: -1, count: cellButtons.count)
    gridStack.contentSize = CGSize(width: available, height: entries.isEmpty ? 0 : y + rowPitch)
  }

  private func updateVisibleCells() {
    // Keep the small panel fully materialized for accessibility. A long list only needs the
    // current viewport and one row of overscan; scrolls reuse the same buttons.
    let allVisible = entries.count <= RimeCandidatePanelModel.cellsPerPage
    let lower = gridStack.contentOffset.y - rowPitch
    let upper = gridStack.contentOffset.y + gridStack.bounds.height + rowPitch
    var visible: [Int] = []
    var first = 0
    if !allVisible {
      var low = 0
      var high = cellFrames.count
      while low < high {
        let middle = (low + high) / 2
        if cellFrames[middle].maxY < lower {
          low = middle + 1
        } else {
          high = middle
        }
      }
      first = low
    }
    for index in first..<cellFrames.count {
      let frame = cellFrames[index]
      if allVisible || (frame.maxY >= lower && frame.minY <= upper) {
        visible.append(index)
      } else if !allVisible && frame.minY > upper {
        break
      }
    }
    ensureCells(visible.count)
    let visibleSet = Set(visible)
    for slot in cellButtons.indices where displayedIndices[slot] >= 0
      && !visibleSet.contains(displayedIndices[slot]) {
      cellButtons[slot].isHidden = true
      displayedIndices[slot] = -1
    }
    for index in visible {
      if displayedIndices.contains(index) { continue }
      guard let slot = displayedIndices.firstIndex(of: -1) else { continue }
      let button = cellButtons[slot]
      let entry = entries[index]
      button.isHidden = false
      button.frame = cellFrames[index]
      button.tag = entry.index
      button.accessibilityLabel = entry.label.map { $0 + ". " + entry.text } ?? entry.text
      button.accessibilityValue = entry.comment
      button.setTitle(entry.text, for: .normal)
      button.backgroundColor = entry.isHighlighted ? theme.candidatePanelHighlightFill : .clear
      displayedIndices[slot] = index
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    #if DEBUG
    onScroll?(scrollView.contentOffset.y)
    #endif
    guard !needsCellLayout, entries.count > RimeCandidatePanelModel.cellsPerPage else { return }
    updateVisibleCells()
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
