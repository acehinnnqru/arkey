import XCTest
import UIKit
import RimeEngine

@MainActor
final class KeyboardReentryCompatibilityTests: XCTestCase {
  func testCompensationDoesNotAccumulateAndNewProcessStartsUnadjusted() {
    let session = KeyboardReentryCompatibility(isEnabled: true)
    XCTAssertEqual(session.nextTopReduction, 0)
    XCTAssertEqual(session.presentationCount, 0)
    XCTAssertEqual(session.beginPresentation().topReduction, 0)
    for number in 2...5 {
      XCTAssertEqual(session.nextTopReduction, 17)
      let appearance = session.beginPresentation()
      XCTAssertEqual(appearance.number, number)
      XCTAssertEqual(appearance.topReduction, 17)
    }
    XCTAssertEqual(KeyboardReentryCompatibility(isEnabled: true).beginPresentation().topReduction, 0)
    let disabled = KeyboardReentryCompatibility(isEnabled: false)
    for _ in 0..<3 { XCTAssertEqual(disabled.beginPresentation().topReduction, 0) }
  }

  private func descendants<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
    let matches = (root as? T).map { [$0] } ?? []
    return matches + root.subviews.flatMap { descendants(type, in: $0) }
  }

  func testReusedAndReplacementControllersReduceOnlyCandidateSpace() throws {
    let restore = try overridePreference(true)
    defer { restore() }
    let session = KeyboardReentryCompatibility(isEnabled: true)
    let first = KeyboardViewController(reentryCompatibility: session)
    defer { first.viewWillDisappear(false) }
    first.loadViewIfNeeded()
    // Preparing a controller does not consume the first presentation.
    XCTAssertEqual(session.presentationCount, 0)
    first.viewWillAppear(false)
    try checkGeometry(first, reduction: 0)
    first.viewWillDisappear(false)
    first.viewWillAppear(false)
    try checkGeometry(first, reduction: 17)
    first.viewWillDisappear(false)

    let replacement = KeyboardViewController(reentryCompatibility: session)
    replacement.loadViewIfNeeded()
    defer { replacement.viewWillDisappear(false) }
    XCTAssertEqual(replacement.inputView?.intrinsicContentSize.height,
                   KeyboardMetrics.totalHeight(needsGlobeRow: replacement.needsInputModeSwitchKey) - 17)
    replacement.viewWillAppear(false)
    XCTAssertEqual(session.presentationCount, 3)
    try checkGeometry(replacement, reduction: 17)
  }

  private func overridePreference(_ enabled: Bool) throws -> () -> Void {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: RimeKeyboardPreferencesStore.appGroupID))
    let key = RimeKeyboardPreferencesStore.storageKey
    let original = defaults.object(forKey: key)
    let store = RimeKeyboardPreferencesStore(defaults: defaults)
    var value = store.value
    value.reentryCompensationEnabled = enabled
    store.value = value
    return {
      if let original { defaults.set(original, forKey: key) }
      else { defaults.removeObject(forKey: key) }
    }
  }

  func testSwitchRestoresHeightAndAlignmentOnNextAppearanceWithoutRestart() throws {
    let restore = try overridePreference(true)
    defer { restore() }
    let session = KeyboardReentryCompatibility(isEnabled: true)
    let controller = KeyboardViewController(reentryCompatibility: session)
    defer { controller.viewWillDisappear(false) }
    controller.loadViewIfNeeded()
    controller.viewWillAppear(false)
    controller.viewWillDisappear(false)
    controller.viewWillAppear(false)
    try checkGeometry(controller, reduction: 17)
    controller.viewWillDisappear(false)

    let store = try XCTUnwrap(RimeKeyboardPreferencesStore.appGroup())
    var preferences = store.value
    preferences.reentryCompensationEnabled = false
    store.value = preferences
    controller.viewWillAppear(false)
    try checkGeometry(controller, reduction: 0)
    controller.viewWillDisappear(false)
    let replacement = KeyboardViewController(reentryCompatibility: session)
    replacement.loadViewIfNeeded()
    XCTAssertEqual(replacement.inputView?.intrinsicContentSize.height,
                   KeyboardMetrics.totalHeight(needsGlobeRow: replacement.needsInputModeSwitchKey))

    preferences.reentryCompensationEnabled = true
    store.value = preferences
    controller.viewWillAppear(false)
    try checkGeometry(controller, reduction: 17)
  }

  private func checkGeometry(_ controller: KeyboardViewController, reduction: CGFloat) throws {
    let root = try XCTUnwrap(controller.inputView as? KeyboardInputView)
    let height = KeyboardMetrics.totalHeight(needsGlobeRow: controller.needsInputModeSwitchKey) - reduction
    XCTAssertEqual(root.keyboardHeight, height)
    XCTAssertEqual(root.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height, height)
    let hostHeight = root.heightAnchor.constraint(equalToConstant: height)
    hostHeight.isActive = true
    defer { hostHeight.isActive = false }
    root.frame = CGRect(x: 0, y: 0, width: 430, height: height)
    root.setNeedsLayout()
    root.layoutIfNeeded()
    let bar = try XCTUnwrap(descendants(CandidateBar.self, in: root).first)
    let grid = try XCTUnwrap(descendants(KeyboardKeyGrid.self, in: root).first)
    grid.layoutIfNeeded()
    XCTAssertEqual(bar.frame.minY, 0, accuracy: 0.01)
    XCTAssertEqual(bar.frame.height, 52 - reduction, accuracy: 0.01)
    XCTAssertEqual(bar.contentVerticalOffset,
                   KeyboardMetrics.candidateContentOffset(slotHeight: 52 - reduction, topReduction: reduction))
    XCTAssertEqual(grid.frame.minY, bar.frame.maxY, accuracy: 0.01)
    XCTAssertEqual(grid.frame.maxY, height - 5, accuracy: 0.01)
    let keys = descendants(KeyButton.self, in: grid)
    XCTAssertFalse(keys.isEmpty)
    for key in keys {
      XCTAssertEqual(key.bounds.height, KeyboardMetrics.keyHeight, accuracy: 0.01)
      XCTAssertTrue(root.bounds.contains(key.convert(key.bounds, to: root)))
    }

    let panel = try XCTUnwrap(descendants(CandidatePanelView.self, in: root).first)
    XCTAssertEqual(panel.candidateSlotHeight, 52 - reduction)
    XCTAssertEqual(panel.contentVerticalOffset, bar.contentVerticalOffset)
    panel.applyContinuation([RimeCandidateItem(text: "test")], startingAt: 0, resetScroll: true)
    panel.isHidden = false
    grid.isHidden = true
    panel.layoutIfNeeded()
    let collapse = try XCTUnwrap(descendants(UIButton.self, in: panel).first {
      $0.currentImage != nil && $0.bounds.width == CandidateBar.accessoryWidth
    })
    XCTAssertEqual(collapse.bounds.height, bar.bounds.height, accuracy: 0.01)
    XCTAssertEqual(root.keyboardHeight, height, "expanding candidates must not change the requested height")
    panel.isHidden = true
    grid.isHidden = false
  }
}
