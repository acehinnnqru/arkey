import Foundation

/// Bounded snapshots across a keyboard presentation, retaining the transient peak.
struct KeyboardGeometryTrace {
  private(set) var isFinished = false
  private var count = 0
  private var peakHeight: CGFloat = -1
  private var requestedHeights = Set<CGFloat>()
  private var globeStates = Set<Bool>()
  private var first: String?
  private var peak: String?
  private var last: String?
  private var displaySamples = 0
  private var presentationSamples = 0
  private var displayPeak: CGFloat = 0
  private var mismatchSamples = 0
  private var mismatchSampledSeconds: CFTimeInterval = 0
  private var mismatchFirst: CFTimeInterval?
  private var mismatchLast: CFTimeInterval?

  /// Count every display callback, including unchanged geometry omitted from
  /// the verbose snapshots. These are sampled timing estimates, not video frames.
  mutating func recordDisplayFrame(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval,
                                  modelHeight: CGFloat, presentationHeight: CGFloat?,
                                  requestedHeight: CGFloat) {
    guard !isFinished else { return }
    displaySamples += 1
    if presentationHeight != nil { presentationSamples += 1 }
    displayPeak = max(displayPeak, modelHeight, presentationHeight ?? 0)
    guard abs(modelHeight - requestedHeight) > 0.5
      || presentationHeight.map({ abs($0 - requestedHeight) > 0.5 }) == true else { return }
    mismatchSamples += 1
    mismatchSampledSeconds += max(0, targetTimestamp - timestamp)
    if mismatchFirst == nil { mismatchFirst = timestamp }
    mismatchLast = max(timestamp, targetTimestamp)
  }

  mutating func record(height: CGFloat, requestedHeight: CGFloat?, needsGlobe: Bool, message: String) {
    guard !isFinished else { return }
    count += 1
    if first == nil { first = message }
    if height > peakHeight {
      peakHeight = height
      peak = message
    }
    last = message
    if let requestedHeight { requestedHeights.insert(requestedHeight) }
    globeStates.insert(needsGlobe)
  }

  mutating func finish(reason: String) -> String? {
    guard let summary = snapshot(reason: reason) else { return nil }
    isFinished = true
    return summary
  }

  /// Ending display-link sampling must not stop later lifecycle/layout records.
  /// Keep only the first, peak and latest geometry, regardless of session length.
  func snapshot(reason: String) -> String? {
    guard !isFinished, let first, let last else { return nil }
    let heights = requestedHeights.sorted().map { String(format: "%.2f", $0) }.joined(separator: ",")
    let states = globeStates.map(String.init).sorted().joined(separator: ",")
    var parts = ["geometry summary reason=\(reason) samples=\(count)"
      + " peakHeight=\(String(format: "%.2f", peakHeight)) requested=[\(heights)] needsGlobe=[\(states)]"
      + " displaySamples=\(displaySamples) presentationSamples=\(presentationSamples)"
      + " displayPeak=\(String(format: "%.2f", displayPeak))"
      + " mismatchSamples=\(mismatchSamples)"
      + " mismatchSampledMs=\(String(format: "%.2f", mismatchSampledSeconds * 1000))"
      + " mismatchSpanMs=\(String(format: "%.2f", ((mismatchLast ?? 0) - (mismatchFirst ?? 0)) * 1000))",
      "first: " + first]
    if let peak, peak != first, peak != last { parts.append("peak: " + peak) }
    if last != first { parts.append("last: " + last) }
    return parts.joined(separator: "\n")
  }
}
