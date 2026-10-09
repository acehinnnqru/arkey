import SwiftUI
import UIKit
import RimeEngine

/// Live preview of the keyboard's view hierarchy inside the host app.
///
/// It exists because a keyboard extension cannot be driven from a simulator without tapping the
/// globe, which is precisely how a layout crash reached a device unnoticed. Rendering the same
/// views here turns that class of bug into something a screenshot catches.
struct KeyboardPreview: UIViewRepresentable {
  var auxiliaryPrefix: String = ","
  var auxiliaryKeySide: RimeKeyboardPreferences.AuxiliaryKeySide = .right

  func makeUIView(context: Context) -> KeyboardPreviewView {
    let view = KeyboardPreviewView()
    view.configure(auxiliaryPrefix: auxiliaryPrefix, auxiliaryKeySide: auxiliaryKeySide)
    return view
  }

  func updateUIView(_ uiView: KeyboardPreviewView, context: Context) {
    uiView.configure(auxiliaryPrefix: auxiliaryPrefix, auxiliaryKeySide: auxiliaryKeySide)
  }
}

final class KeyboardPreviewView: UIView {
  private let candidateBar = CandidateBar()
  private let keyGrid = KeyboardKeyGrid()

  override init(frame: CGRect) {
    super.init(frame: frame)
    let theme = KeyboardTheme.current(for: .light)
    backgroundColor = theme.background

    candidateBar.apply(theme: theme)
    candidateBar.translatesAutoresizingMaskIntoConstraints = false
    keyGrid.translatesAutoresizingMaskIntoConstraints = false
    addSubview(candidateBar)
    addSubview(keyGrid)

    NSLayoutConstraint.activate([
      candidateBar.topAnchor.constraint(equalTo: topAnchor),
      candidateBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      candidateBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      candidateBar.heightAnchor.constraint(equalToConstant: KeyboardMetrics.candidateBarHeight),
      // Same stack as the extension's: the slot is the bar plus the room under it, so the grid starts at the
      // bar's bottom and the whole thing is exactly `totalHeight`, which is the frame this preview is given.
      keyGrid.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
      keyGrid.leadingAnchor.constraint(equalTo: leadingAnchor),
      keyGrid.trailingAnchor.constraint(equalTo: trailingAnchor),
      keyGrid.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    // The same model the keyboard renders, so the preview cannot drift from the real bar: labels,
    // comments, the highlighted cell and the page chevrons all come from one type.
    candidateBar.setPage(RimePage(candidates: [
      RimeCandidateItem(text: "你好", comment: "ni hao"),
      RimeCandidateItem(text: "你"),
      RimeCandidateItem(text: "拟"),
      RimeCandidateItem(text: "尼"),
    ], highlightedIndex: 0, pageNumber: 1, pageSize: 5, isLastPage: false,
       selectLabels: ["1", "2", "3", "4"]))

  }

  func configure(auxiliaryPrefix: String,
                 auxiliaryKeySide: RimeKeyboardPreferences.AuxiliaryKeySide) {
    keyGrid.configure(theme: KeyboardTheme.current(for: .light),
                      layer: .letters,
                      asciiMode: false,
                      returnKeyLabel: "换行",
                      showsGlobeRow: true,
                      auxiliaryPrefix: auxiliaryPrefix,
                      auxiliaryKeySide: auxiliaryKeySide)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }
}

#if DEBUG
/// A deterministic surface for gesture tests; it is shown only with the UI-test launch argument.
struct CandidateScrollTestScreen: View {
  var body: some View {
    CandidateScrollTestFixture()
      .frame(height: 350)
      .padding()
  }
}

private struct CandidateScrollTestFixture: UIViewRepresentable {
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
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.onScroll = { [weak barOffset] value in barOffset?.text = String(Int(value)) }
    bar.onSelect = { [weak selection] value in selection?.text = "bar-\(value)" }
    let candidates = (0..<500).map { RimeCandidateItem(text: "Candidate \($0)") }
    var loadedCount = 5
    var loading = false
    bar.applyContinuation(Array(candidates.prefix(loadedCount)))
    bar.onNeedsMoreCandidates = { [weak bar] in
      guard !loading, loadedCount < candidates.count else { return }
      loading = true
      DispatchQueue.main.async {
        loadedCount = min(loadedCount + 24, candidates.count)
        bar?.applyContinuation(Array(candidates.prefix(loadedCount)))
        loading = false
      }
    }
    let panel = CandidatePanelView()
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
      panel.topAnchor.constraint(equalTo: bar.bottomAnchor),
      panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    panel.applyContinuation((0..<500).map { RimeCandidateItem(text: "候选词\($0)") }, startingAt: 0)
    return container
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
