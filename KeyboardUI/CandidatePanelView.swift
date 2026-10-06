import UIKit
import RimeEngine

/// Expanded candidates wrap at their natural text width and scroll within the keyboard.
final class CandidatePanelView: UIView {
  /// A cell was tapped: the argument is librime's own candidate index, not the cell's position.
  var onSelect: ((Int) -> Void)?
  var onCollapse: (() -> Void)?
  /// Page the grid. Never commits (S3 §5).
  var onPage: ((Bool) -> Void)?

  private let syllableRow = UIStackView()
  private let syllables = UILabel()
  private let headerSpacer = UIView()
  private let leadingButton = UIButton(type: .system)
  private let trailingButton = UIButton(type: .system)
  private let collapseButton = UIButton(type: .system)
  private let gridStack = UIScrollView()
  private var rowPitch = RimeCandidatePanelModel.rowPitch
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
    gridStack.alwaysBounceVertical = true
    gridStack.delaysContentTouches = false
    addSubview(gridStack)

    for _ in 0..<RimeCandidatePanelModel.cellsPerPage {
      let button = UIButton(type: .custom)
      button.titleLabel?.font = .systemFont(ofSize: 20)
      button.titleLabel?.adjustsFontSizeToFitWidth = false
      button.titleLabel?.lineBreakMode = .byTruncatingTail
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
      button.clipsToBounds = true
      button.layer.cornerRadius = 8
      button.layer.cornerCurve = .continuous
      button.addTarget(self, action: #selector(handleCell(_:)), for: .touchUpInside)
      gridStack.addSubview(button)
      cellButtons.append(button)
    }

    NSLayoutConstraint.activate([
      syllableRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: KeyboardMetrics.sideMargin),
      syllableRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -KeyboardMetrics.sideMargin),
      syllableRow.topAnchor.constraint(equalTo: topAnchor),
      syllableRow.heightAnchor.constraint(equalToConstant: syllableHeight),
      leadingButton.widthAnchor.constraint(equalToConstant: 32),
      trailingButton.widthAnchor.constraint(equalToConstant: 32),
      collapseButton.widthAnchor.constraint(equalToConstant: 32),
      gridStack.leadingAnchor.constraint(equalTo: leadingAnchor,
                                         constant: KeyboardMetrics.sideMargin),
      gridStack.trailingAnchor.constraint(equalTo: trailingAnchor,
                                          constant: -KeyboardMetrics.sideMargin),
      gridStack.topAnchor.constraint(equalTo: syllableRow.bottomAnchor),
      gridStack.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    for button in cellButtons {
      button.setTitleColor(theme.candidateText, for: .normal)
    }
  }

  func apply(model: RimeCandidatePanelModel) {
    showsSyllables = !(model.syllableRow ?? []).isEmpty
    syllableHeight = model.syllableRowHeight
    rowPitch = model.rowPitch
    gridHeight = model.gridHeight
    headerSpacer.isHidden = showsSyllables
    syllables.isHidden = !showsSyllables
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
    gridStack.setContentOffset(.zero, animated: false)
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    syllableRow.layoutIfNeeded()
    let available = gridStack.bounds.width
    guard available > 0 else { return }
    var x: CGFloat = 0
    var y: CGFloat = 0
    for button in cellButtons where !button.isHidden {
      let text = button.title(for: .normal) ?? ""
      let measured = (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 20)]).width
      let width = min(available, max(44, ceil(measured) + 24))
      if x > 0 && x + width > available {
        x = 0
        y += rowPitch
      }
      button.frame = CGRect(x: x, y: y, width: width, height: rowPitch)
      x += width
    }
    gridStack.contentSize = CGSize(width: available, height: y + rowPitch)
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
