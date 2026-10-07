import UIKit
import RimeEngine

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
  /// The cap role, which comes from the engine's rule (S3 §4) through the grid's translation of its own
  /// vocabulary of keys.
  private var role: RimeKeyCapRole = .letter
  private var theme = KeyboardTheme.current(for: .default)

  var key: KeyboardKey?
  /// Repeat is only used by the delete key.
  var repeatsWhileHeld = false
  /// The touch's life, for the callout: down, moved (in this view's coordinates) and ended.
  var onTouchDown: ((CGPoint) -> Void)?
  var onTouchMove: ((CGPoint) -> Void)?
  var onTouchEnded: (() -> Void)?
  /// The feedback policy in force. The controller sets it from the shared preferences on every
  /// appearance, so a calibration change reaches the keyboard without a rebuild.
  var feedback = RimeKeyFeedback.standard

  private var repeatTimer: Timer?
  private var repeatDelayWorkItem: DispatchWorkItem?
  private var isPressed = false

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

  func apply(theme: KeyboardTheme, style: Style, role: RimeKeyCapRole) {
    self.theme = theme
    self.style = style
    self.role = role
    backgroundColor = theme.fill(for: role)
    let text = isAction ? theme.returnKeyText : textColor(for: style)
    titleLabel.textColor = text
    imageView.tintColor = text
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = style == .plain ? 0 : theme.keyShadowOpacity
  }

  /// What the cap draws. The label is private like the rest of the view's insides; this is the part a test
  /// (and anything else that needs to read a key back) can see.
  var title: String? { titleLabel.text }

  func setTitle(_ title: String, pointSize: CGFloat = 22) {
    titleLabel.text = title
    titleLabel.font = .systemFont(ofSize: pointSize, weight: .regular)
    imageView.image = nil
  }

  func setSymbol(_ name: String, pointSize: CGFloat = 20) {
    titleLabel.text = nil
    imageView.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
  }

  private var isAction: Bool { role == .actionEnabled || role == .actionDisabled }

  /// The cap while a finger is on it. A key with no cap keeps none — the globe used to flash the pressed wide
  /// colour, because the pressed path asked only whether the key was wide.
  private var pressedRole: RimeKeyCapRole {
    switch role {
    case .letter: return .pressedLetter
    case .wide: return .pressedWide
    case .pressedLetter, .pressedWide, .actionEnabled, .actionDisabled, .plain: return role
    }
  }

  private func textColor(for style: Style) -> UIColor {
    style == .active ? theme.activeKeyText : theme.keyText
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    if let touch = touches.first { onTouchMove?(touch.location(in: self)) }
    super.touchesMoved(touches, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    // UIKit normally sends touchUpInside/Outside. Also clear a press if the control was
    // interrupted while the finger was moving, so neither the cap nor delete repeat sticks.
    if isPressed { handleTouchUp() }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    if isPressed { handleTouchUp() }
  }

  override func willMove(toSuperview newSuperview: UIView?) {
    if newSuperview == nil && isPressed { handleTouchUp() }
    super.willMove(toSuperview: newSuperview)
  }

  @objc private func handleTouchDown() {
    isPressed = true
    onTouchDown?(CGPoint(x: bounds.midX, y: bounds.midY))
    // S3 §5: the cap shifts to its pressed fill and nothing else moves. The fill is the palette's,
    // so it moves in the direction the measured appearance says it moves.
    backgroundColor = theme.fill(for: pressedRole)
    guard repeatsWhileHeld else { return }
    let feedback = self.feedback
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.repeatTimer = Timer.scheduledTimer(withTimeInterval: feedback.deleteRepeatInterval,
                                              repeats: true) { [weak self] _ in
        self?.sendActions(for: .primaryActionTriggered)
      }
    }
    repeatDelayWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + feedback.deleteRepeatDelay, execute: work)
  }

  /// Single entry point for the controller: one action per tap, plus repeats from the timer.
  @objc private func handlePrimary() {
    sendActions(for: .primaryActionTriggered)
  }

  @objc private func handleTouchUp() {
    isPressed = false
    onTouchEnded?()
    backgroundColor = theme.fill(for: role)
    repeatDelayWorkItem?.cancel()
    repeatDelayWorkItem = nil
    repeatTimer?.invalidate()
    repeatTimer = nil
  }
}
