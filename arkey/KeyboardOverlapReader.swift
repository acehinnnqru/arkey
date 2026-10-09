import SwiftUI
import UIKit

/// Measure overlap in the host content's coordinates, including after navigation.
/// UIKit owns the guide's updates and safe-area accounting.
struct KeyboardOverlapReader: UIViewRepresentable {
  var onChange: (CGFloat) -> Void

  func makeUIView(context: Context) -> KeyboardOverlapView {
    let view = KeyboardOverlapView()
    view.onChange = onChange
    return view
  }

  func updateUIView(_ uiView: KeyboardOverlapView, context: Context) {
    uiView.onChange = onChange
    uiView.setNeedsLayout()
  }
}

final class KeyboardOverlapView: UIView {
  var onChange: ((CGFloat) -> Void)?
  private let overlap = UIView()
  private var lastHeight: CGFloat = -1

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    overlap.translatesAutoresizingMaskIntoConstraints = false
    addSubview(overlap)
    NSLayoutConstraint.activate([
      overlap.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
      overlap.bottomAnchor.constraint(equalTo: bottomAnchor),
      overlap.leadingAnchor.constraint(equalTo: leadingAnchor),
      overlap.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let height = max(0, min(bounds.height, overlap.frame.height - safeAreaInsets.bottom))
    guard abs(height - lastHeight) > 0.5 else { return }
    lastHeight = height
    DispatchQueue.main.async { [weak self] in
      guard let self, self.lastHeight == height else { return }
      self.onChange?(height)
    }
  }
}
