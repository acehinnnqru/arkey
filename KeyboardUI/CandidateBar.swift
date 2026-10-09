import UIKit
import RimeEngine

/// A drag beginning on a candidate must be able to cancel the button's tracking.
private final class CandidateBarScrollView: UIScrollView {
  override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// The suggestion strip above the keys — S4 §6's collapsed bar, rendered from `RimeCandidateBarModel`.
///
/// Three rules earned the hard way, kept from the tracer's version:
///  - every constraint is anchored inside the view that owns it, so no activation can happen between
///    two views that share no ancestor (that threw on the first key press and killed the extension);
///  - buttons are pooled and updated in place to keep keystrokes inexpensive;
///  - a keystroke that changes nothing visible must not restyle anything.
final class CandidateBar: UIView, UIScrollViewDelegate {
  /// Called with the index of the tapped candidate on the current page.
  var onSelect: ((Int) -> Void)?
  /// A long press forgets the word (S4 §8, S5-AC5). The index is the cell's position on the page the bar is
  /// showing, which is the numbering librime's `delete_candidate` expects.
  var onForget: ((Int) -> Void)?
  /// Called with `backward` for a page turn. Page keys never commit (S3 §5).
  var onPage: ((Bool) -> Void)?
  /// The expand control: S4 §6's panel replaces the keyboard area, so the bar has to offer it.
  var onExpand: (() -> Void)?
  #if DEBUG
  var onScroll: ((CGFloat) -> Void)?
  #endif

  private let expandButton = UIButton(type: .system)
  private let cellsStack = UIView()
  private let scrollView = CandidateBarScrollView()
  private var preferredWidths: [CGFloat] = []
  private let outerStack = UIStackView()
  private let messageLabel = UILabel()
  private var cellButtons: [UIButton] = []
  private var theme = KeyboardTheme.current(for: .default)
  private var currentModel: RimeCandidateBarModel?

  private static let chevronWidth: CGFloat = 64
  /// Only omit a prefix from the expanded panel when that entire prefix remains visible.
  var visibleCandidateCount: Int {
    guard scrollView.contentOffset.x <= 0 else { return 0 }
    return cellButtons.prefix { !$0.isHidden && $0.frame.maxX <= scrollView.bounds.width }.count
  }

  func setExpanded(_ expanded: Bool) {
    expandButton.setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down"), for: .normal)
    expandButton.accessibilityLabel = expanded ? "收起候选面板" : "展开候选面板"
  }

  /// Turn pages only after dragging beyond an edge of the current page.
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    guard let model = currentModel else { return }
    let end = max(0, scrollView.contentSize.width - scrollView.bounds.width)
    if scrollView.contentOffset.x < -44 && model.pageNumber > 0 {
      onPage?(true)
    } else if scrollView.contentOffset.x > end + 44 && !model.isLastPage {
      onPage?(false)
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    #if DEBUG
    onScroll?(scrollView.contentOffset.x)
    #endif
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    scrollView.delegate = self
    scrollView.alwaysBounceHorizontal = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.delaysContentTouches = true
    scrollView.canCancelContentTouches = true
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.accessibilityIdentifier = "candidate-bar-scroll"
    scrollView.addSubview(cellsStack)

    outerStack.axis = .horizontal
    outerStack.alignment = .fill
    outerStack.distribution = .fill
    outerStack.spacing = 0
    outerStack.translatesAutoresizingMaskIntoConstraints = false
    outerStack.addArrangedSubview(scrollView)
    outerStack.addArrangedSubview(expandButton)
    addSubview(outerStack)

    expandButton.translatesAutoresizingMaskIntoConstraints = false
    expandButton.tintColor = .secondaryLabel
    expandButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
    expandButton.accessibilityLabel = "展开候选面板"
    expandButton.addTarget(self, action: #selector(handleExpand), for: .touchUpInside)

    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.numberOfLines = 2
    messageLabel.lineBreakMode = .byTruncatingTail
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(messageLabel)

    NSLayoutConstraint.activate([
      outerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      outerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      outerStack.topAnchor.constraint(equalTo: topAnchor),
      outerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
      expandButton.widthAnchor.constraint(equalToConstant: Self.chevronWidth),
      messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  func apply(theme: KeyboardTheme) {
    self.theme = theme
    backgroundColor = .clear
    messageLabel.textColor = theme.candidateText.withAlphaComponent(0.75)
    for chevron in [expandButton] {
      chevron.tintColor = theme.candidateText.withAlphaComponent(0.6)
    }
    for button in cellButtons {
      button.setTitleColor(theme.candidateText, for: .normal)
    }
  }

  // MARK: - The model

  func apply(model: RimeCandidateBarModel) {
    let changed = currentModel != model
    currentModel = model
    if changed {
      scrollView.setContentOffset(.zero, animated: false)
    }
    guard !model.isEmpty else {
      showMessage(model.message ?? "")
      return
    }
    hideMessage()
    expandButton.isHidden = false

    let count = model.cells.count
    ensureCells(count: count)

    preferredWidths = model.cells.prefix(count).map { max(44, ceil(Self.title(for: $0, theme: theme).size().width) + 24) }
    for (index, button) in cellButtons.enumerated() {
      let visible = index < count
      button.isHidden = !visible
      guard visible else { continue }
      let cell = model.cells[index]
      button.tag = cell.index
      button.accessibilityLabel = cell.label.map { $0 + ". " + cell.text } ?? cell.text
      button.accessibilityValue = cell.comment
      let title = Self.title(for: cell, theme: theme)
      if button.attributedTitle(for: .normal) != title {
        button.setAttributedTitle(title, for: .normal)
      }
      button.setTitleColor(theme.candidateText, for: .normal)
      let fill = UIColor.clear
      if button.backgroundColor != fill {
        button.backgroundColor = fill
      }
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    outerStack.layoutIfNeeded()
    let available = scrollView.bounds.width
    guard available > 0, !preferredWidths.isEmpty else { return }
    var x: CGFloat = 0
    for (index, button) in cellButtons.enumerated() {
      button.isHidden = index >= preferredWidths.count
      guard index < preferredWidths.count else { continue }
      let width = preferredWidths[index]
      button.frame = CGRect(x: x, y: 0, width: width, height: scrollView.bounds.height)
      x += width
    }
    cellsStack.frame = CGRect(x: 0, y: 0, width: max(available, x), height: scrollView.bounds.height)
    scrollView.contentSize = cellsStack.bounds.size
  }

  /// The convenience the controller uses: a whole page from the engine.
  func setPage(_ page: RimePage?, message: String? = nil) {
    apply(model: RimeCandidateBarModel.page(page, message: message))
  }

  /// Boot diagnostics. The candidate strip is the one piece of screen real estate the keyboard
  /// always owns, so this is where a device user can read what happened.
  func setMessage(_ message: String) {
    showMessage(message)
  }

  // MARK: - Internals

  /// The cell's title: the candidate, its select label when the schema defines one, and its comment
  /// in a smaller face (拼音, emoji) the way the system's bar shows them.
  private static func title(for cell: RimeCandidateCell,
                           theme: KeyboardTheme) -> NSAttributedString {
    let text = NSMutableAttributedString(
      string: cell.text,
      attributes: [.font: UIFont.systemFont(ofSize: 20),
                   .foregroundColor: theme.candidateText])
    if let label = cell.label, !label.isEmpty {
      let prefix = NSAttributedString(
        string: label + " ",
        attributes: [.font: UIFont.systemFont(ofSize: 12),
                     .foregroundColor: theme.candidateText.withAlphaComponent(0.55)])
      text.insert(prefix, at: 0)
    }
    if let comment = cell.comment, !comment.isEmpty {
      text.append(NSAttributedString(
        string: " " + comment,
        attributes: [.font: UIFont.systemFont(ofSize: 12),
                     .foregroundColor: theme.candidateText.withAlphaComponent(0.55)]))
    }
    return text
  }

  private func showMessage(_ message: String) {
    scrollView.setContentOffset(.zero, animated: false)
    outerStack.isHidden = true
    expandButton.isHidden = true
    messageLabel.text = message
    messageLabel.isHidden = message.isEmpty
  }

  private func hideMessage() {
    messageLabel.text = nil
    messageLabel.isHidden = true
    outerStack.isHidden = false
  }

  @objc private func handleTap(_ sender: UIButton) {
    onSelect?(sender.tag)
  }

  /// A long press forgets the candidate under the finger. The gesture fires on `.began` only, so a hold does
  /// not forget twice.
  @objc private func handleForget(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began,
          let button = recognizer.view as? UIButton,
          let index = cellButtons.firstIndex(of: button) else { return }
    onForget?(index)
  }

  @objc private func handleExpand() {
    onExpand?()
  }

  private func ensureCells(count: Int) {
    while cellButtons.count < count {
      let button = UIButton(type: .custom)
      button.titleLabel?.adjustsFontSizeToFitWidth = false
      button.contentHorizontalAlignment = .left
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
      button.clipsToBounds = true
      button.titleLabel?.lineBreakMode = .byTruncatingTail
      button.tag = cellButtons.count
      button.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)
      let forget = UILongPressGestureRecognizer(target: self, action: #selector(handleForget(_:)))
      forget.delaysTouchesBegan = false
      forget.delaysTouchesEnded = false
      button.addGestureRecognizer(forget)
      cellsStack.addSubview(button)
      cellButtons.append(button)
    }
  }

}
