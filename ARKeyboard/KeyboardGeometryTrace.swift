import Foundation

/// One bounded record per keyboard presentation, retaining the transient peak.
struct KeyboardGeometryTrace {
  private(set) var isFinished = false
  private var count = 0
  private var peakHeight: CGFloat = -1
  private var requestedHeights = Set<CGFloat>()
  private var globeStates = Set<Bool>()
  private var first: String?
  private var peak: String?
  private var last: String?

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
    guard !isFinished, let first, let last else { return nil }
    isFinished = true
    let heights = requestedHeights.sorted().map { String(format: "%.2f", $0) }.joined(separator: ",")
    let states = globeStates.map(String.init).sorted().joined(separator: ",")
    var parts = ["geometry summary reason=\(reason) samples=\(count)"
      + " peakHeight=\(String(format: "%.2f", peakHeight)) requested=[\(heights)] needsGlobe=[\(states)]",
      "first: " + first]
    if let peak, peak != first, peak != last { parts.append("peak: " + peak) }
    if last != first { parts.append("last: " + last) }
    return parts.joined(separator: "\n")
  }
}
