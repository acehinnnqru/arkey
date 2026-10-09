import UIKit
import RimeEngine

/// S3 §5's key callout: the magnified cap that follows the finger across the grid.
///
/// The frame is always `RimeCalloutGeometry`'s, because an extension cannot draw outside its own frame
/// — a callout that escaped would be clipped or, worse, move the keyboard. On the first row there is
/// only the candidate slot above the key, so the callout is limited to that space.
final class KeyCalloutView: UIView {
  private let label = UILabel()
  private let tail = UIView()
  private var theme = KeyboardTheme.current(for: .default)

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    layer.cornerCurve = .continuous
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.18
    layer.shadowOffset = CGSize(width: 0, height: 1)
    layer.shadowRadius = 2

    label.textAlignment = .center
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.5
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    tail.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tail)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      tail.centerXAnchor.constraint(equalTo: centerXAnchor),
      tail.bottomAnchor.constraint(equalTo: bottomAnchor),
      tail.widthAnchor.constraint(equalToConstant: 12),
      tail.heightAnchor.constraint(equalToConstant: 6),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = RimeKeyFeedback.standard.calloutRadius
    tail.layer.cornerRadius = 1
  }

  func apply(theme: KeyboardTheme) {
    self.theme = theme
    backgroundColor = theme.keyFill
    label.textColor = theme.keyText
    tail.backgroundColor = theme.keyFill
  }

  /// Shows the callout for a key at the geometry's frame. The label is the key's own, so a shift key
  /// drawn as a symbol still says what it does.
  func show(label text: String, frame: CGRect) {
    self.frame = frame
    label.text = text
    isHidden = false
  }

  func move(to frame: CGRect) {
    self.frame = frame
  }

  func hide() {
    isHidden = true
  }

  var isShowing: Bool { !isHidden }
}
