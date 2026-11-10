import SwiftUI
import UIKit
import RimeEngine

#if DEBUG
/// A deterministic surface for gesture tests; it is shown only with the UI-test launch argument.
struct CandidateScrollTestScreen: View {
  @Environment(\.locale) private var interfaceLocale
  var body: some View {
    let _ = interfaceLocale
    CandidateScrollTestFixture(reflow: ProcessInfo.processInfo.arguments.contains("--candidate-reflow-ui-test"))
      .frame(height: 350)
      .padding()
  }
}

private struct CandidateScrollTestFixture: UIViewRepresentable {
  var reflow: Bool
  func makeUIView(context: Context) -> UIView {
    let container = UIView()
    let offset = UILabel()
    offset.accessibilityIdentifier = "candidate-offset"
    offset.text = "0"
    offset.translatesAutoresizingMaskIntoConstraints = false
    let selection = UILabel()
    selection.accessibilityIdentifier = "candidate-selection"
    selection.text = "none"
    selection.translatesAutoresizingMaskIntoConstraints = false
    let barOffset = UILabel()
    barOffset.accessibilityIdentifier = "candidate-bar-offset"
    barOffset.text = "0"
    barOffset.translatesAutoresizingMaskIntoConstraints = false
    let bar = CandidateBar()
    let panel = CandidatePanelView()
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.onScroll = { [weak barOffset] value in barOffset?.text = String(Int(value)) }
    bar.onSelect = { [weak selection] value in selection?.text = "bar-\(value)" }
    let candidates = (0..<500).map { RimeCandidateItem(text: "Candidate \($0)") }
    var loadedCount = 5
    var loading = false
    bar.applyContinuation(Array(candidates.prefix(loadedCount)))
    bar.onNeedsMoreCandidates = { [weak bar, weak panel] in
      guard !loading, loadedCount < candidates.count else { return }
      loading = true
      DispatchQueue.main.async {
        loadedCount = min(loadedCount + 24, candidates.count)
        bar?.applyContinuation(Array(candidates.prefix(loadedCount)))
        if reflow {
          panel?.applyContinuation(Array(candidates.prefix(loadedCount)), startingAt: 0)
        }
        loading = false
      }
    }
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.onScroll = { [weak offset] value in offset?.text = String(Int(value)) }
    panel.onSelect = { [weak selection] value in selection?.text = String(value) }
    container.addSubview(offset)
    container.addSubview(selection)
    container.addSubview(barOffset)
    container.addSubview(bar)
    container.addSubview(panel)
    NSLayoutConstraint.activate([
      offset.topAnchor.constraint(equalTo: container.topAnchor),
      offset.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      selection.topAnchor.constraint(equalTo: container.topAnchor),
      selection.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      barOffset.topAnchor.constraint(equalTo: container.topAnchor),
      barOffset.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      bar.topAnchor.constraint(equalTo: offset.bottomAnchor),
      bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bar.heightAnchor.constraint(equalToConstant: KeyboardMetrics.candidateBarHeight),
      panel.topAnchor.constraint(equalTo: reflow ? offset.bottomAnchor : bar.bottomAnchor),
      panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    if reflow {
      panel.isHidden = true
      panel.applyContinuation(Array(candidates.prefix(loadedCount)), startingAt: 0)
      bar.onExpand = { [weak bar, weak panel] in
        bar?.isHidden = true
        panel?.isHidden = false
        panel?.applyContinuation(Array(candidates.prefix(loadedCount)), startingAt: 0, resetScroll: true)
        panel?.requestMoreCandidatesIfNeeded()
      }
      panel.onCollapse = { [weak bar, weak panel] in
        panel?.isHidden = true
        bar?.isHidden = false
      }
      panel.onNeedsMoreCandidates = bar.onNeedsMoreCandidates
    } else {
      let whitespaceFixture = ProcessInfo.processInfo.arguments.contains("--candidate-whitespace-ui-test")
      panel.applyContinuation((0..<500).map { index in
        let word = whitespaceFixture
          ? (index % 2 == 0 ? "A" : "A candidate that occupies an entire row")
          : RimeLocalization.text("Candidate \(index)")
        return RimeCandidateItem(text: word)
      }, startingAt: 0)
    }
    // Exercise the same passive observer as the extension while testing physical candidate gestures.
    let touches = CandidateTouchObserver()
    touches.roleAtPoint = { [weak bar, weak panel] point in
      if let panel, !panel.isHidden, panel.frame.contains(point) { return "scroll" }
      if let bar, !bar.isHidden, bar.frame.contains(point),
         point.x >= bar.frame.maxX - CandidateBar.accessoryWidth { return "expand" }
      return nil
    }
    container.addGestureRecognizer(touches)
    return container
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
