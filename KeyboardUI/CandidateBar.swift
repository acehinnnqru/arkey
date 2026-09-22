import UIKit
import RimeEngine

/// The suggestion strip above the keys: a fixed row of candidates, laid out like the system
/// suggestion bar.
///
/// Deliberately constraint-light. Every constraint is anchored inside the view that owns it, so
/// no activation can ever happen between two views that share no ancestor — that mistake threw
/// an NSInternalInconsistencyException on the first key press and took the whole keyboard down.
final class CandidateBar: UIView {
  private let stack = UIStackView()
  private let messageLabel = UILabel()
  private var buttons: [UIButton] = []
  private var theme = KeyboardTheme.current(for: .default)

  /// Called with the tapped candidate index.
  var onSelect: ((Int) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)

    stack.axis = .horizontal
    stack.alignment = .fill
    stack.distribution = .fillEqually
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.numberOfLines = 2
    messageLabel.lineBreakMode = .byTruncatingTail
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(messageLabel)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    backgroundColor = theme.background
    messageLabel.textColor = theme.candidateText.withAlphaComponent(0.75)
    for button in buttons {
      button.setTitleColor(theme.candidateText, for: .normal)
    }
  }

  func setCandidates(_ candidates: [RimeCandidateItem], highlighted: Int) {
    clearCandidates()
    messageLabel.isHidden = !candidates.isEmpty
    stack.isHidden = candidates.isEmpty

    for (index, candidate) in candidates.enumerated() {
      let button = UIButton(type: .custom)
      button.setTitle(candidate.text, for: .normal)
      button.setTitleColor(theme.candidateText, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 20)
      button.titleLabel?.adjustsFontSizeToFitWidth = true
      button.titleLabel?.minimumScaleFactor = 0.6
      button.tag = index
      button.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)
      if index == highlighted {
        button.backgroundColor = theme.candidateHighlightFill
      }
      if index > 0 {
        addSeparator(to: button)
      }
      stack.addArrangedSubview(button)
      buttons.append(button)
    }
  }

  /// Boot diagnostics. The candidate strip is the one piece of screen real estate the keyboard
  /// always owns, so this is where a device user can read what happened.
  func setMessage(_ message: String) {
    clearCandidates()
    stack.isHidden = true
    messageLabel.isHidden = false
    messageLabel.text = message
  }

  @objc private func handleTap(_ sender: UIButton) {
    onSelect?(sender.tag)
  }

  private func clearCandidates() {
    for button in buttons {
      stack.removeArrangedSubview(button)
      button.removeFromSuperview()
    }
    buttons.removeAll()
  }

  /// The separator lives inside its own candidate's bounds, so both anchors always belong to
  /// views that share a superview before the constraint is activated.
  private func addSeparator(to host: UIView) {
    let separator = UIView()
    separator.backgroundColor = theme.separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(separator)
    NSLayoutConstraint.activate([
      separator.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      separator.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      separator.widthAnchor.constraint(equalToConstant: 1),
      separator.heightAnchor.constraint(equalTo: host.heightAnchor, multiplier: 0.5),
    ])
  }
}
