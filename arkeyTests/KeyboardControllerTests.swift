import XCTest
import UIKit
import RimeEngine

/// The extension's controller, instantiated and booted — the closest thing to running the keyboard that this
/// machine can do without a person in front of it.
///
/// The extension's sources are compiled into the test bundle (the project's test target includes its folder),
/// the test host is the app, and the bundled profile ships a prebuilt build directory, so the controller's own
/// boot runs for real: KeyboardEngine.setup locates the workspace, resolves the profile, creates the engine,
/// starts it, opens a session, and reports the status line the bar shows. Nothing here is mocked; a failure is
/// the keyboard a user would see.
final class KeyboardControllerTests: XCTestCase {
  private var controllers: [KeyboardViewController] = []

  override func tearDownWithError() throws {
    for controller in controllers { controller.viewWillDisappear(false) }
    controllers.removeAll()
  }

  /// A controller with a keyboard-shaped view: 430 pt wide, the measured width, and tall enough for the
  /// candidate bar, the rows and the bottom inset the constraints ask for. Off a window nothing lays itself
  /// out, so the test gives it the size the system would give it on a phone.
  private func booted() -> KeyboardViewController {
    let controller = KeyboardViewController()
    controllers.append(controller)
    controller.loadViewIfNeeded()
    controller.viewWillAppear(false)
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 420)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    return controller
  }

  private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
    var found: [T] = []
    if let match = view as? T { found.append(match) }
    for sub in view.subviews { found.append(contentsOf: descendants(type, in: sub)) }
    return found
  }

  /// Every string the view shows, button titles included: the bar's message is a label, its candidates are
  /// buttons, and the test should not have to know which is which.
  private func texts(in view: UIView) -> [String] {
    var found: [String] = []
    if let label = view as? UILabel, let text = label.text, !text.isEmpty { found.append(text) }
    if let button = view as? UIButton {
      if let title = button.title(for: .normal), !title.isEmpty { found.append(title) }
      // The candidate cells carry an attributed title (the candidate plus its select label and comment),
      // which title(for:) does not report.
      if let title = button.attributedTitle(for: .normal)?.string, !title.isEmpty { found.append(title) }
    }
    for sub in view.subviews { found.append(contentsOf: texts(in: sub)) }
    return found
  }

  private func keys(_ controller: KeyboardViewController) throws -> [KeyButton] {
    let grid = try XCTUnwrap(descendants(KeyboardKeyGrid.self, in: controller.view).first,
                             "the controller has no key grid")
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    return grid.subviews.compactMap { $0 as? KeyButton }
  }

  private func bar(_ controller: KeyboardViewController) throws -> CandidateBar {
    try XCTUnwrap(descendants(CandidateBar.self, in: controller.view).first,
                  "the controller has no candidate bar")
  }

  func testChineseOnlyPreferenceRemovesLanguageKeyAndRestoresItOnNextAppearance() throws {
    let store = try XCTUnwrap(RimeKeyboardPreferencesStore.appGroup())
    let original = store.value
    defer { store.value = original }
    var preferences = original
    preferences.chineseInputOnly = false
    store.value = preferences
    let controller = booted()
    let initialKeys = try keys(controller)
    XCTAssertTrue(initialKeys.contains { if case .language? = $0.key { return true }; return false })
    let initialSpace = try XCTUnwrap(initialKeys.first { $0.key == .space }).frame.width
    controller.viewWillDisappear(false)
    preferences.chineseInputOnly = true
    store.value = preferences
    controller.viewWillAppear(false)
    let chineseKeys = try keys(controller)
    XCTAssertFalse(chineseKeys.contains { if case .language? = $0.key { return true }; return $0.key == .emoji })
    XCTAssertGreaterThan(try XCTUnwrap(chineseKeys.first { $0.key == .space }).frame.width, initialSpace)
    if case .success(let setup) = KeyboardEngine.setup {
      XCTAssertFalse(try setup.engine.getOption("ascii_mode"))
    } else {
      XCTFail("The keyboard engine must boot for this test")
    }
    controller.viewWillDisappear(false)
    preferences.chineseInputOnly = false
    store.value = preferences
    controller.viewWillAppear(false)
    let restoredKeys = try keys(controller)
    XCTAssertTrue(restoredKeys.contains { if case .language? = $0.key { return true }; return false })
    XCTAssertEqual(try XCTUnwrap(restoredKeys.first { $0.key == .space }).frame.width,
                   initialSpace, accuracy: 0.01)
  }

  /// A transition cover must not turn the entire temporary host frame into an
  /// opaque rectangle or replace the system material after the transition.
  func testTheTransitionCoverIsBoundedAndCanReturnToTheHostMaterial() throws {
    let controller = booted()
    controller.viewWillAppear(false)
    let root = try XCTUnwrap(controller.inputView as? KeyboardInputView)
    XCTAssertEqual(root.inputViewStyle, .default)
    XCTAssertFalse(root.isOpaque)
    XCTAssertEqual(root.backgroundColor, .clear)
    root.applyBacking(color: .darkGray, fixed: false, needsTransitionCover: true)
    let backing = try XCTUnwrap(root.subviews.first {
      $0.accessibilityIdentifier == "Arkey.contentBacking"
    })
    let hostHeight = root.heightAnchor.constraint(equalToConstant: 932)
    hostHeight.isActive = true
    defer { hostHeight.isActive = false }
    root.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
    root.setNeedsLayout()
    root.layoutIfNeeded()
    XCTAssertFalse(backing.isHidden)
    XCTAssertFalse(backing.isUserInteractionEnabled)
    XCTAssertEqual(backing.backgroundColor?.cgColor.alpha, 1)
    XCTAssertEqual(backing.frame.height, root.keyboardHeight, accuracy: 0.5)
    XCTAssertEqual(backing.frame.minY, 932 - root.keyboardHeight, accuracy: 0.5)
    root.applyBacking(color: .darkGray, fixed: false, needsTransitionCover: false)
    XCTAssertTrue(backing.isHidden)
    XCTAssertEqual(root.backingMode, "host")
    root.applyBacking(color: .darkGray, fixed: true, needsTransitionCover: false)
    XCTAssertFalse(backing.isHidden)
    XCTAssertEqual(root.backingMode, "fixed")
    XCTAssertEqual(try bar(controller).backgroundColor, .clear)
    let panel = try XCTUnwrap(descendants(CandidatePanelView.self, in: root).first)
    XCTAssertEqual(panel.backgroundColor, .clear)
    XCTAssertFalse(panel.isOpaque)
  }

  func testBackingPreferenceIsAdoptedOnTheNextAppearance() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: RimeKeyboardPreferencesStore.appGroupID))
    let key = RimeKeyboardPreferencesStore.storageKey
    let original = defaults.object(forKey: key)
    defer {
      if let original { defaults.set(original, forKey: key) }
      else { defaults.removeObject(forKey: key) }
    }
    let store = RimeKeyboardPreferencesStore(defaults: defaults)
    var preferences = store.value
    preferences.paletteMode = .fixed
    store.value = preferences
    let controller = booted()
    let root = try XCTUnwrap(controller.inputView as? KeyboardInputView)
    XCTAssertEqual(root.backingMode, "fixed")
    controller.viewWillDisappear(false)
    preferences.paletteMode = .followHost
    store.value = preferences
    controller.viewWillAppear(false)
    XCTAssertEqual(root.backingMode, "transition")
  }

  /// The host must be able to measure the keyboard before appearance begins, and
  /// intermediate dismissal frames must not expose keys outside that surface.
  func testKeyboardHeightIsReadyBeforePresentation() throws {
    let controller = KeyboardViewController()
    controllers.append(controller)
    controller.loadViewIfNeeded()
    let root = try XCTUnwrap(controller.inputView)
    XCTAssertTrue(root.allowsSelfSizing)
    let height = try XCTUnwrap(root.constraints.first {
      $0.identifier == "Arkey.keyboardHeight" && $0.isActive
    })
    XCTAssertEqual(height.constant,
                   KeyboardMetrics.totalHeight(needsGlobeRow: controller.needsInputModeSwitchKey))
    let firstHeight = root.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
    XCTAssertEqual(firstHeight, height.constant, accuracy: 0.01)
    XCTAssertTrue(root.clipsToBounds)
    controller.viewWillAppear(false)
    controller.viewDidAppear(false)
    controller.viewDidLayoutSubviews()
    controller.viewWillDisappear(false)
    controller.viewWillAppear(false)
    controller.viewDidLayoutSubviews()
    XCTAssertEqual(root.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height,
                   firstHeight, accuracy: 0.01,
                   "first presentation and return from navigation must use the same height")
    XCTAssertTrue(height.isActive)
    XCTAssertEqual(root.constraints.filter {
      $0.identifier == "Arkey.keyboardHeight" && $0.isActive
    }.count, 1)
  }

  func testCandidateAndExpandHitTargetsCoverTheEntireRowAfterRefreshes() throws {
    let controller = booted()
    let root = try XCTUnwrap(controller.inputView)
    let strip = try bar(controller)
    for width: CGFloat in [320, 430, 900] {
      root.frame.size.width = width
      for _ in 0..<10 {
        strip.setPage(nil)
        strip.applyContinuation((0..<40).map { RimeCandidateItem(text: "Word \($0)") })
        root.setNeedsLayout()
        root.layoutIfNeeded()
        strip.layoutIfNeeded()
        let expand = try XCTUnwrap(descendants(UIButton.self, in: strip).first {
          $0.accessibilityLabel == RimeLocalization.text("Expand candidates")
        })
        XCTAssertEqual(expand.bounds.width, 64, accuracy: 0.1)
        XCTAssertEqual(expand.bounds.height, KeyboardMetrics.candidateBarHeight, accuracy: 0.1)
        for x in stride(from: CGFloat(1), to: width, by: 3) {
          for y in [CGFloat(1), strip.bounds.midY, strip.bounds.maxY - 1] {
            let point = strip.convert(CGPoint(x: x, y: y), to: root)
            let target = try XCTUnwrap(root.hitTest(point, with: nil) as? UIButton,
                                      "The entire candidate row must hit a control at \(x),\(y)")
            XCTAssertTrue(target.isDescendant(of: strip))
            XCTAssertGreaterThanOrEqual(target.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(target.bounds.height, 44)
            if x > width - 64 { XCTAssertTrue(target === expand) }
          }
        }
      }
    }
  }

  func testExpandedCandidateContentDoesNotResizeKeyboard() throws {
    let controller = booted()
    let root = try XCTUnwrap(controller.inputView)
    let before = root.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
    let panel = try XCTUnwrap(descendants(CandidatePanelView.self, in: root).first)
    panel.applyContinuation((0..<500).map { RimeCandidateItem(text: "候选词\($0)") },
                            startingAt: 0, resetScroll: true)
    panel.isHidden = false
    try XCTUnwrap(descendants(KeyboardKeyGrid.self, in: root).first).isHidden = true
    root.layoutIfNeeded()
    let after = root.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
    XCTAssertEqual(after, before, accuracy: 0.5,
                   "candidate content must scroll inside the existing keyboard frame")
  }

  func testHostHeightFromAnotherKeyboardDoesNotChangeFittingHeight() throws {
    let controller = KeyboardViewController()
    controllers.append(controller)
    controller.loadViewIfNeeded()
    let root = try XCTUnwrap(controller.inputView)
    let expected = KeyboardMetrics.totalHeight(needsGlobeRow: controller.needsInputModeSwitchKey)
    // A host can retain its previous keyboard's frame during an input-mode switch.
    let hostHeight = root.heightAnchor.constraint(equalToConstant: expected + 80)
    hostHeight.isActive = true
    defer { hostHeight.isActive = false }
    root.frame = CGRect(x: 0, y: 0, width: 430, height: expected + 80)
    XCTAssertEqual(root.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height,
                   expected, accuracy: 0.01)
    XCTAssertEqual(root.systemLayoutSizeFitting(
      CGSize(width: 430, height: expected + 80),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .required).height,
      expected, accuracy: 0.01)
  }

  func testFullScreenHostTransitionDoesNotStretchKeyboardContent() throws {
    let controller = booted()
    let root = try XCTUnwrap(controller.inputView)
    let grid = try XCTUnwrap(descendants(KeyboardKeyGrid.self, in: root).first)
    let candidate = try bar(controller)
    let panel = try XCTUnwrap(descendants(CandidatePanelView.self, in: root).first)
    let expected = KeyboardMetrics.totalHeight(needsGlobeRow: controller.needsInputModeSwitchKey)
    let hostHeight = root.heightAnchor.constraint(equalToConstant: expected)
    hostHeight.isActive = true
    defer { hostHeight.isActive = false }
    var normalKeyFrames: [CGRect] = []
    for height in [expected, 932, expected + 80, expected] {
      hostHeight.constant = height
      root.frame = CGRect(x: 0, y: 0, width: 430, height: height)
      root.setNeedsLayout()
      root.layoutIfNeeded()
      let keyFrames = try keys(controller).map(\.frame)
      if normalKeyFrames.isEmpty { normalKeyFrames = keyFrames }
      XCTAssertEqual(keyFrames, normalKeyFrames,
                     "temporary host heights must not resize the key caps or row gaps")
      XCTAssertEqual(grid.bounds.height,
                     expected - KeyboardMetrics.candidateBarHeight - KeyboardMetrics.keyBottomPadding,
                     accuracy: 0.5)
      XCTAssertEqual(candidate.frame.minY, height - expected, accuracy: 0.5)
      XCTAssertEqual(candidate.frame.maxY, grid.frame.minY, accuracy: 0.5)
      XCTAssertEqual(grid.frame.maxY, height - KeyboardMetrics.keyBottomPadding, accuracy: 0.5)
      XCTAssertEqual(panel.frame.minY, candidate.frame.minY, accuracy: 0.5)
      XCTAssertEqual(panel.frame.height, expected, accuracy: 0.5)
    }
  }

  /// The engine behind the extension boots, and the bar says so. The failure this catches is the one a user
  /// sees: a sentence where the keyboard should be.
  func testTheKeyboardBoots() throws {
    let controller = booted()
    let shown = texts(in: try bar(controller))
    let status = shown.first { $0.hasPrefix("Arkey") }
    XCTAssertNotNil(status, "the bar never reported a boot: " + shown.joined(separator: " | "))
    XCTAssertTrue(status?.hasPrefix("Arkey 就绪") == true,
                  "the keyboard did not boot: " + (status ?? "nothing"))
  }

  /// The keys exist and are placed, from the engine's own layout. The geometry tests build a grid themselves;
  /// this is the controller's wiring, which nothing else covers.
  func testTheControllerLaysOutItsKeys() throws {
    let buttons = try keys(booted())
    XCTAssertGreaterThanOrEqual(buttons.count, 30, "the controller built no keyboard")
    XCTAssertTrue(buttons.allSatisfy { !$0.frame.isEmpty }, "some keys were never placed")
    XCTAssertTrue(buttons.contains { $0.accessibilityLabel?.isEmpty == false },
                  "the keys carry no accessibility labels")
  }

  /// A tap goes all the way through: the button's action reaches the controller, the controller calls the
  /// engine, and the bar reacts. On this machine the workspace has **no deployed profile** — the app deploys
  /// on its first launch, and nothing here has opened the app — so the engine falls back to the bundled one
  /// and answers no candidates. That is the state a user meets on a fresh install, and it must be a keyboard
  /// that types rather than a crash or a blank bar, so it is pinned rather than skipped. The deployed case
  /// (a real candidate after a real deploy) is the device run's step 3.
  func testATapReachesTheEngineBeforeAnythingIsDeployed() throws {
    let controller = booted()
    let bar = try bar(controller)
    XCTAssertTrue(texts(in: bar).contains { $0.hasPrefix("Arkey 就绪") },
                  "the keyboard did not boot, so the tap proves nothing")
    let before = texts(in: bar)

    let n = try XCTUnwrap(try keys(controller).first { $0.key == .character("n") }, "no n key")
    n.sendActions(for: .primaryActionTriggered)

    // The bar stopped showing the boot line, which is what it does when a key produces a page — even an
    // empty one. Nothing crashed, and the grid is still there to type the next key.
    let after = texts(in: bar)
    XCTAssertNotEqual(after, before, "the tap never reached the bar")
    XCTAssertFalse(try keys(controller).isEmpty, "the keyboard disappeared after one key")
  }

  /// The frame the extension asks for holds every key it draws. A keyboard the system has to clip is a keyboard
  /// with a row of cut caps, which is what a device sent in round 191: `123 / 中 / 空格 / 换行` came back 34 pt
  /// tall instead of 45, with the cut running straight across all four. The grid used to start one row gap below
  /// the candidate bar — 11 pt lower than the slot the height counts — so the bottom row hung below the frame.
  func testTheFrameTheExtensionAsksForHoldsEveryKey() throws {
    let controller = KeyboardViewController()
    controllers.append(controller)
    controller.loadViewIfNeeded()
    controller.viewWillAppear(false)
    let asked = KeyboardMetrics.totalHeight(needsGlobeRow: controller.needsInputModeSwitchKey)
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: asked)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    let grid = try XCTUnwrap(descendants(KeyboardKeyGrid.self, in: controller.view).first,
                             "the controller has no key grid")
    let buttons = try keys(controller)
    XCTAssertGreaterThanOrEqual(buttons.count, 30, "the controller built no keyboard")

    // The frame is what the system clips with, so this is the boundary that matters.
    for button in buttons {
      let frame = button.convert(button.bounds, to: controller.view)
      XCTAssertLessThanOrEqual(frame.maxY, controller.view.bounds.maxY + 0.5,
                               "a key ends " + String(format: "%.1f", frame.maxY - controller.view.bounds.maxY)
                                 + " pt below the frame the extension asks for")
    }
    // And the rows end where the grid does: a keyboard shorter than its frame leaves a band of empty backing,
    // which is the other half of the same disagreement (round 189).
    let rows = buttons.map(\.frame.maxY).max() ?? 0
    XCTAssertEqual(rows, grid.bounds.height, accuracy: 0.5,
                   "the rows do not fill the grid: " + String(format: "%.1f", rows) + " pt of keys in "
                     + String(format: "%.1f", grid.bounds.height) + " pt of grid")
    XCTAssertEqual(grid.frame.maxY, controller.view.bounds.maxY - 5, accuracy: 0.5)
  }
}
