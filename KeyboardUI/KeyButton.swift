import UIKit

/// One key cap. Drawn as a plain view so that the system-like fill, corner radius and
/// pressed state stay under our control.
final class KeyButton: UIControl {
  enum Style {
    case letter
    case special
    case active
    /// Transparent key, used by the globe.
    case plain
  }

  private let titleLabel = UILabel()
  private let imageView = UIImageView()
  private var style: Style = .letter
  private var theme = KeyboardTheme.current(for: .default)

  var key: KeyboardKey?
  /// Repeat is only used by the delete key.
  var repeatsWhileHeld = false

  private var repeatTimer: Timer?
  private var repeatDelayWorkItem: DispatchWorkItem?

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = KeyboardMetrics.cornerRadius
    layer.cornerCurve = .continuous
    layer.shadowOffset = CGSize(width: 0, height: 1)
    layer.shadowRadius = 0

    titleLabel.textAlignment = .center
    titleLabel.adjustsFontSizeToFitWidth = true
    titleLabel.minimumScaleFactor = 0.7
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(titleLabel)

    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)

    NSLayoutConstraint.activate([
      titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.86),
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 24),
      imageView.heightAnchor.constraint(equalToConstant: 24),
    ])

    addTarget(self, action: #selector(handleTouchDown), for: [.touchDown, .touchDragEnter])
    addTarget(self, action: #selector(handleTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    addTarget(self, action: #selector(handlePrimary), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  deinit {
    repeatTimer?.invalidate()
    repeatDelayWorkItem?.cancel()
  }

  func apply(theme: KeyboardTheme, style: Style) {
    self.theme = theme
    self.style = style
    backgroundColor = fill(for: style)
    titleLabel.textColor = textColor(for: style)
    imageView.tintColor = textColor(for: style)
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = style == .plain ? 0 : theme.keyShadowOpacity
  }

  func setTitle(_ title: String, pointSize: CGFloat = 22) {
    titleLabel.text = title
    titleLabel.font = .systemFont(ofSize: pointSize, weight: .regular)
    imageView.image = nil
  }

  func setSymbol(_ name: String, pointSize: CGFloat = 20) {
    titleLabel.text = nil
    imageView.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
  }

  private func fill(for style: Style) -> UIColor {
    switch style {
    case .letter: return theme.keyFill
    case .special: return theme.specialKeyFill
    case .active: return theme.activeKeyFill
    case .plain: return .clear
    }
  }

  private func textColor(for style: Style) -> UIColor {
    style == .active ? theme.activeKeyText : theme.keyText
  }

  @objc private func handleTouchDown() {
    alpha = 0.7
    guard repeatsWhileHeld else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
        self?.sendActions(for: .primaryActionTriggered)
      }
    }
    repeatDelayWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
  }

  /// Single entry point for the controller: one action per tap, plus repeats from the timer.
  @objc private func handlePrimary() {
    sendActions(for: .primaryActionTriggered)
  }

  @objc private func handleTouchUp() {
    alpha = 1
    repeatDelayWorkItem?.cancel()
    repeatDelayWorkItem = nil
    repeatTimer?.invalidate()
    repeatTimer = nil
  }
}
