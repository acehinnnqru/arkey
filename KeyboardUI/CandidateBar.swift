import UIKit
import RimeEngine

/// The suggestion strip above the keys: a fixed row of candidates, laid out like the system
/// suggestion bar.
///
/// Two rules earned the hard way:
///  - every constraint is anchored inside the view that owns it, so no activation can happen
///    between two views that share no ancestor (that threw on the first key press and killed the
///    extension);
///  - buttons are pooled and updated in place. Creating and destroying five buttons plus
///    separators on every keystroke was a large part of why typing felt laggy.
final class CandidateBar: UIView {
  private static let maxCandidates = 5

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
    guard !candidates.isEmpty else {
      stack.isHidden = true
      messageLabel.isHidden = (messageLabel.text ?? "").isEmpty
      return
    }
    // The first real candidate retires the boot diagnostics for good.
    messageLabel.text = nil
    messageLabel.isHidden = true
    stack.isHidden = false

    let count = min(candidates.count, Self.maxCandidates)
    ensureButtons(count: count)

    for (index, button) in buttons.enumerated() {
      let visible = index < count
      button.isHidden = !visible
      guard visible else { continue }
      let title = candidates[index].text
      if button.title(for: .normal) != title {
        button.setTitle(title, for: .normal)
      }
      let fill = index == highlighted ? theme.candidateHighlightFill : UIColor.clear
      if button.backgroundColor != fill {
        button.backgroundColor = fill
      }
    }
  }

  /// Boot diagnostics. The candidate strip is the one piece of screen real estate the keyboard
  /// always owns, so this is where a device user can read what happened.
  func setMessage(_ message: String) {
    stack.isHidden = true
    messageLabel.text = message
    messageLabel.isHidden = message.isEmpty
  }

  @objc private func handleTap(_ sender: UIButton) {
    onSelect?(sender.tag)
  }

  private func ensureButtons(count: Int) {
    while buttons.count < count {
      let button = UIButton(type: .custom)
      button.setTitleColor(theme.candidateText, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 20)
      button.titleLabel?.adjustsFontSizeToFitWidth = true
      button.titleLabel?.minimumScaleFactor = 0.6
      button.tag = buttons.count
      button.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)
      if !buttons.isEmpty {
        addSeparator(to: button)
      }
      stack.addArrangedSubview(button)
      buttons.append(button)
    }
  }

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
