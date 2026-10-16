import UIKit

#if DEBUG
/// Observe delivery before UIKit decides between a tap and a pan, without participating in that decision.
final class CandidateTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
  var roleAtPoint: ((CGPoint) -> String?)?
  var onSample: ((String, TimeInterval, String) -> Void)?
  private struct Sample {
    let role: String
    let origin: CGPoint
    var moved = false
  }
  private var samples: [ObjectIdentifier: Sample] = [:]

  init() {
    super.init(target: nil, action: nil)
    delegate = self
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }

  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    roleAtPoint?(touch.location(in: view)) != nil
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    for touch in touches {
      let point = touch.location(in: view)
      guard let role = roleAtPoint?(point) else { continue }
      let sample = Sample(role: role, origin: point)
      samples[ObjectIdentifier(touch)] = sample
      report("began", touch: touch, sample: sample)
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    for touch in touches {
      let key = ObjectIdentifier(touch)
      guard var sample = samples[key], !sample.moved else { continue }
      let point = touch.location(in: view)
      guard hypot(point.x - sample.origin.x, point.y - sample.origin.y) >= 10 else { continue }
      sample.moved = true
      samples[key] = sample
      report("moved", touch: touch, sample: sample)
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, phase: "ended") }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, phase: "cancelled") }

  private func finish(_ touches: Set<UITouch>, phase: String) {
    for touch in touches {
      if let sample = samples.removeValue(forKey: ObjectIdentifier(touch)) {
        report(phase, touch: touch, sample: sample)
      }
    }
    if samples.isEmpty { state = .failed }
  }

  override func reset() {
    super.reset()
    samples.removeAll(keepingCapacity: true)
  }

  private func report(_ phase: String, touch: UITouch, sample: Sample) {
    let point = touch.location(in: view)
    let recognizers = (touch.gestureRecognizers ?? []).filter { $0 !== self }.map {
      "\(type(of: $0)):state=\($0.state.rawValue):delaysBegan=\($0.delaysTouchesBegan):delaysEnded=\($0.delaysTouchesEnded)"
    }.joined(separator: ",")
    onSample?(phase, touch.timestamp,
      "role=\(sample.role) tapCount=\(touch.tapCount)"
        + " deltaX=\(String(format: "%.1f", point.x - sample.origin.x))"
        + " deltaY=\(String(format: "%.1f", point.y - sample.origin.y)) recognizers=[\(recognizers)]")
  }
}
#endif
