import UIKit
import RimeEngine

/// S4 §6's expanded panel: the keyboard area is replaced, so no key is reachable while it is open.
///
/// Everything about its shape comes from `RimeCandidatePanelModel` — the 6 × 6 grid, the 45 pt row
/// pitch, the 63.3 pt the panel reaches above the keyboard's own top, and the syllable row's own
/// 39.7 pt slot when librime offers a segmentation at all.
///
/// One deviation from the capture, recorded rather than hidden: the grid pages by tapping the
/// chevrons in the syllable row instead of by scrolling, because a scroll view inside a keyboard
/// extension is a gesture fight with the host that this round did not take on.
final class CandidatePanelView: UIView {
  /// A cell was tapped: the argument is librime's own candidate index, not the cell's position.
  var onSelect: ((Int) -> Void)?
  var onCollapse: (() -> Void)?
  /// Page the grid. Never commits (S3 §5).
  var onPage: ((Bool) -> Void)?

  private let syllableRow = UIStackView()
  private let syllables = UILabel()
  private let leadingButton = UIButton(type: .system)
  private let trailingButton = UIButton(type: .system)
  private let collapseButton = UIButton(type: .system)
  private let gridStack = UIStackView()
  private var rowStacks: [UIStackView] = []
  private var cellButtons: [UIButton] = []
  private var theme = KeyboardTheme.current(for: .default)

  private var gridHeight: CGFloat = CGFloat(RimeCandidatePanelModel.rows)
    * RimeCandidatePanelModel.rowPitch
  private var syllableHeight: CGFloat = RimeCandidatePanelModel.syllableRowHeight
  private var showsSyllables = false

  override init(frame: CGRect) {
    super.init(frame: frame)

    syllableRow.axis = .horizontal
    syllableRow.alignment = .fill
    syllableRow.distribution = .fill
    syllableRow.spacing = 4
    syllableRow.translatesAutoresizingMaskIntoConstraints = false
    syllableRow.addArrangedSubview(leadingButton)
    syllableRow.addArrangedSubview(syllables)
    syllableRow.addArrangedSubview(trailingButton)
    syllableRow.addArrangedSubview(collapseButton)
    addSubview(syllableRow)

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

    gridStack.axis = .vertical
    gridStack.alignment = .fill
    gridStack.distribution = .fillEqually
    gridStack.spacing = 0
    gridStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(gridStack)

    for _ in 0..<RimeCandidatePanelModel.rows {
      let row = UIStackView()
      row.axis = .horizontal
      row.alignment = .fill
      row.distribution = .fillEqually
      row.spacing = 0
      for _ in 0..<RimeCandidatePanelModel.columns {
        let button = UIButton(type: .custom)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.5
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        button.addTarget(self, action: #selector(handleCell(_:)), for: .touchUpInside)
        row.addArrangedSubview(button)
        cellButtons.append(button)
      }
      gridStack.addArrangedSubview(row)
      rowStacks.append(row)
    }

    NSLayoutConstraint.activate([
      syllableRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: KeyboardMetrics.sideMargin),
      syllableRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -KeyboardMetrics.sideMargin),
      syllableRow.topAnchor.constraint(equalTo: topAnchor,
                                       constant: RimeCandidatePanelModel.topOverhang),
      syllableRow.heightAnchor.constraint(equalToConstant: syllableHeight),
      leadingButton.widthAnchor.constraint(equalToConstant: 32),
      trailingButton.widthAnchor.constraint(equalToConstant: 32),
      collapseButton.widthAnchor.constraint(equalToConstant: 32),
      gridStack.leadingAnchor.constraint(equalTo: leadingAnchor,
                                         constant: KeyboardMetrics.sideMargin),
      gridStack.trailingAnchor.constraint(equalTo: trailingAnchor,
                                          constant: -KeyboardMetrics.sideMargin),
      gridStack.topAnchor.constraint(equalTo: syllableRow.bottomAnchor),
      gridStack.heightAnchor.constraint(equalToConstant: gridHeight),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// The height the extension has to ask the system for while the panel is open: the panel reaches
  /// above the keyboard's own top, which is what the 63.3 pt overhang is.
  func height(bottomInset: CGFloat) -> CGFloat {
    RimeCandidatePanelModel.topOverhang + syllableHeight + gridHeight + bottomInset
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
    showsSyllables = !(model.syllableRow ?? []).isEmpty
    syllableHeight = showsSyllables ? model.syllableRowHeight : 0
    gridHeight = model.gridHeight
    syllableRow.isHidden = !showsSyllables
    syllables.text = (model.syllableRow ?? []).joined(separator: " ")
    leadingButton.isHidden = model.isFirstPage
    trailingButton.isHidden = model.isLastPage

    for (index, button) in cellButtons.enumerated() {
      guard index < model.cells.count else {
        button.isHidden = true
        continue
      }
      button.isHidden = false
      let cell = model.cells[index]
      button.tag = cell.index
      button.accessibilityLabel = cell.label.map { $0 + ". " + cell.text } ?? cell.text
      button.accessibilityValue = cell.comment
      button.setTitle(cell.text, for: .normal)
      button.backgroundColor = cell.isHighlighted ? theme.candidatePanelHighlightFill : .clear
    }
    invalidateIntrinsicContentSize()
    setNeedsLayout()
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
