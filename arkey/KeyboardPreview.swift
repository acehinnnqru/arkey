import SwiftUI
import UIKit
import RimeEngine

/// Live preview of the keyboard's view hierarchy inside the host app.
///
/// It exists because a keyboard extension cannot be driven from a simulator without tapping the
/// globe, which is precisely how a layout crash reached a device unnoticed. Rendering the same
/// views here turns that class of bug into something a screenshot catches.
struct KeyboardPreview: UIViewRepresentable {
  func makeUIView(context: Context) -> KeyboardPreviewView {
    KeyboardPreviewView()
  }

  func updateUIView(_ uiView: KeyboardPreviewView, context: Context) {}
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

    keyGrid.configure(theme: theme,
                      layer: .letters,
                      asciiMode: false,
                      returnKeyLabel: "换行",
                      showsGlobeRow: true)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }
}
