import Foundation

/// A temporary cover protects a new presentation without replacing the host's
/// material for the entire appearance. Display samples are evidence of sizing,
/// not proof that the compositor displayed a particular pixel.
struct KeyboardBackingState {
  private(set) var needsCover = true
  private(set) var hasAppeared = false
  private var matchingFrames = 0

  mutating func beginAppearance() {
    needsCover = true
    hasAppeared = false
    matchingFrames = 0
  }

  mutating func didAppear() {
    hasAppeared = true
  }

  mutating func sample(modelHeight: CGFloat, presentationHeight: CGFloat?,
                       requestedHeight: CGFloat, attached: Bool) {
    guard needsCover else { return }
    guard hasAppeared, attached, requestedHeight > 0,
          let presentationHeight,
          abs(modelHeight - requestedHeight) <= 0.5,
          abs(presentationHeight - requestedHeight) <= 0.5 else {
      matchingFrames = 0
      return
    }
    matchingFrames += 1
    if matchingFrames >= 2 { needsCover = false }
  }

  /// Never leave a material-following keyboard permanently covered if a host
  /// uses another final size or does not expose a presentation layer in time.
  mutating func endSampling() {
    needsCover = false
  }
}
