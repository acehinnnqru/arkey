import SwiftUI
import UIKit
import RimeEngine

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
  private var diagnosticWork: DispatchWorkItem?
  private var diagnosticFirst: String?
  private var diagnosticLast: String?
  private var diagnosticPeak: String?
  private var diagnosticPeakHeight: CGFloat = -1
  private var diagnosticChanges = 0
  private static let diagnosticQueue = DispatchQueue(label: "com.acehinnnqru.arkey.hostGeometry", qos: .utility)

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
    recordHostGeometry(overlapHeight: height)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.lastHeight == height else { return }
      self.onChange?(height)
    }
  }

  /// Keep a bounded summary of each change burst. The system can add space
  /// outside the extension while its own view remains at the requested height.
  /// Recording this side makes that distinction visible in a device export.
  private func recordHostGeometry(overlapHeight: CGFloat) {
    guard let window else { return }
    let rect: (CGRect) -> String = {
      String(format: "%.2f,%.2f,%.2f,%.2f", $0.minX, $0.minY, $0.width, $0.height)
    }
    let snapshot = "uptime=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))"
      + " overlap=\(String(format: "%.2f", overlapHeight))"
      + " readerInWindow=\(rect(convert(bounds, to: window)))"
      + " guideInWindow=\(rect(convert(keyboardLayoutGuide.layoutFrame, to: window)))"
      + " safeBottom=\(String(format: "%.2f", safeAreaInsets.bottom))"
      + " window=\(rect(window.bounds))"
    diagnosticChanges += 1
    if diagnosticFirst == nil { diagnosticFirst = snapshot }
    diagnosticLast = snapshot
    if overlapHeight > diagnosticPeakHeight {
      diagnosticPeakHeight = overlapHeight
      diagnosticPeak = snapshot
    }
    diagnosticWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.flushHostGeometry() }
    diagnosticWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }

  private func flushHostGeometry() {
    guard let first = diagnosticFirst, let last = diagnosticLast else { return }
    var message = "host geometry trace=height-8 changes=\(diagnosticChanges)"
      + " peakOverlap=\(String(format: "%.2f", diagnosticPeakHeight))\nfirst: " + first
    if let peak = diagnosticPeak, peak != first, peak != last { message += "\npeak: " + peak }
    if last != first { message += "\nlast: " + last }
    diagnosticFirst = nil
    diagnosticLast = nil
    diagnosticPeak = nil
    diagnosticPeakHeight = -1
    diagnosticChanges = 0
    diagnosticWork = nil
    guard let url = ProbeLogLocation.groupLogURL else { return }
    let record = RimeProbeRecord(phase: "app.keyboard.geometry.summary", message: message)
    Self.diagnosticQueue.async { RimeProbeLog(url: url).append(record) }
  }
}
