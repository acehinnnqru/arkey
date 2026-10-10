import XCTest
import UIKit
import RimeEngine

/// The candidate bar and the expanded panel, driven the way a user drives them: a deployed profile, real
/// keystrokes through the grid, a tap on a candidate, and the expand button.
///
/// The bar's labels and chevrons were checked before, and nothing had ever put a *candidate* in it: the
/// keyboard's workspace is undeployed until the app has run once. This test deploys the bundled profile into
/// the keyboard's own container workspace — what the app's first launch does — then lets the controller adopt
/// it at appearance, and undoes the install in tearDown so a re-run starts where the first one did.
///
/// It runs after the controller tests alphabetically, which is what keeps their premise ("nothing is deployed
/// yet") true, and before the deploy test, which uses a workspace of its own.
final class KeyboardTypingTests: XCTestCase {
  private var installed: String?
  private var controllers: [KeyboardViewController] = []

  override func tearDownWithError() throws {
    for controller in controllers { controller.viewWillDisappear(false) }
    controllers.removeAll()
    guard let installed, case .success(let setup) = KeyboardEngine.setup else { return }
    try? RimeDeploymentCoordinator(workspace: setup.workspace, engine: setup.engine)
      .delete(profileID: installed)
    try? FileManager.default.removeItem(at: setup.workspace.activeRecord)
    setup.engine.shutdown()
    self.installed = nil
  }

  private func booted() -> KeyboardViewController {
    let controller = KeyboardViewController()
    controllers.append(controller)
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 420)
    controller.viewWillAppear(false)
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

  private func texts(in view: UIView) -> [String] {
    var found: [String] = []
    if let label = view as? UILabel, let text = label.text, !text.isEmpty { found.append(text) }
    if let button = view as? UIButton {
      if let title = button.title(for: .normal), !title.isEmpty { found.append(title) }
      if let title = button.attributedTitle(for: .normal)?.string, !title.isEmpty { found.append(title) }
    }
    for sub in view.subviews { found.append(contentsOf: texts(in: sub)) }
    return found
  }

  /// Whether a view is actually on screen: the bar hides its cells by hiding the stack they live in, so the
  /// button's own isHidden flag says nothing.
  private func isVisible(_ view: UIView, in root: UIView) -> Bool {
    var current: UIView? = view
    while let node = current, node !== root {
      if node.isHidden { return false }
      current = node.superview
    }
    return true
  }

  private func visibleTitles(in root: UIView) -> [String] {
    descendants(UIButton.self, in: root).filter { isVisible($0, in: root) }
      .compactMap { $0.attributedTitle(for: .normal)?.string }
  }

  private func bar(_ controller: KeyboardViewController) throws -> CandidateBar {
    try XCTUnwrap(descendants(CandidateBar.self, in: controller.view).first, "no candidate bar")
  }

  private func panel(_ controller: KeyboardViewController) throws -> CandidatePanelView {
    try XCTUnwrap(descendants(CandidatePanelView.self, in: controller.view).first, "no candidate panel")
  }

  private func waitForPanelCandidates(_ panel: CandidatePanelView) {
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      panel.layoutIfNeeded()
      return self.descendants(UIButton.self, in: panel).contains {
        !$0.isHidden && $0.title(for: .normal) != nil
      }
    }, object: panel)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 3), .completed)
  }

  /// Installs the bundled profile into the keyboard's workspace with the keyboard's own engine, which is the
  /// app's first-run flow.
  @discardableResult
  private func deployBundledProfile() throws -> String {
    let bundled = try XCTUnwrap(RimeDirectories.bundledSharedDataURL(in: .main), "no bundled RimeData")
    guard case .success(let setup) = KeyboardEngine.setup else {
      throw XCTSkip("the keyboard's engine did not come up in this environment")
    }
    let id = try XCTUnwrap(RimeLocalDataInstaller.installIfPresent(at: bundled, workspace: setup.workspace,
                                                                  engine: setup.engine),
                           "the bundled profile was already the active one")
    installed = id
    return id
  }

  private func type(_ characters: [String], in controller: KeyboardViewController) throws {
    let grid = try XCTUnwrap(descendants(KeyboardKeyGrid.self, in: controller.view).first, "no grid")
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    for character in characters {
      let button = try XCTUnwrap(grid.subviews.compactMap { $0 as? KeyButton }
        .first { $0.key == .character(character) }, "no " + character + " key")
      button.sendActions(for: .primaryActionTriggered)
    }
    // Candidate buttons are materialized during layout to keep offscreen cells cheap.
    controller.view.layoutIfNeeded()
    try bar(controller).layoutIfNeeded()
  }

  func testTypingThroughTheKeyboardPutsTheEnginesCandidatesOnTheBar() throws {
    try deployBundledProfile()
    let controller = booted()
    try type(["n", "i", "h", "a", "o"], in: controller)

    let shown = texts(in: try bar(controller))
    XCTAssertTrue(shown.contains { $0.contains("你好") },
                  "the bar shows: " + shown.joined(separator: " | "))
  }

  func testSwitchingBackFromEnglishProducesChineseCandidates() throws {
    try deployBundledProfile()
    let controller = booted()
    let grid = try XCTUnwrap(descendants(KeyboardKeyGrid.self, in: controller.view).first)
    guard case .success(let setup) = KeyboardEngine.setup else { return XCTFail("engine setup failed") }
    func toggleLanguage() throws {
      let button = try XCTUnwrap(grid.subviews.compactMap { $0 as? KeyButton }.first {
        if case .language = $0.key { return true }
        return false
      })
      button.sendActions(for: .primaryActionTriggered)
      grid.layoutIfNeeded()
    }
    try toggleLanguage()
    XCTAssertTrue(try setup.engine.getOption("ascii_mode"))
    try type(["n"], in: controller)
    XCTAssertFalse(try setup.engine.refresh().isComposing)
    try toggleLanguage()
    XCTAssertFalse(try setup.engine.getOption("ascii_mode"))
    try type(["n", "i", "h", "a", "o"], in: controller)
    XCTAssertTrue(texts(in: try bar(controller)).contains { $0.contains("你好") })
  }

  func testMissingSchemaIsReportedInsteadOfTreatingEnglishFallbackAsReady() throws {
    try deployBundledProfile()
    _ = booted()
    guard case .success(let setup) = KeyboardEngine.setup else { return XCTFail("engine setup failed") }
    let original = setup.engine.directories
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      setup.engine.shutdown()
      _ = try? setup.engine.rebind(to: original)
      try? FileManager.default.removeItem(at: root)
    }
    try "schema_list:\n  - schema: ghost\n".write(to: root.appendingPathComponent("default.yaml"),
                                  atomically: true, encoding: .utf8)
    _ = try setup.engine.rebind(to: RimeDirectories(sharedDataDir: root.path,
                                                    prebuiltDataDir: root.path,
                                                    userDataDir: root.path,
                                                    stagingDir: root.path,
                                                    logDir: root.path))
    try setup.engine.openSession()
    XCTAssertEqual(try setup.engine.currentSchema(), "ghost",
                   "a missing schema can still have a non-placeholder ID")
    try setup.engine.setOption("ascii_mode", false)
    XCTAssertTrue(try setup.engine.processKey(RimeKey.ascii("n")!).needsLiteralFallback,
                  "a missing compiled schema reproduces English-only input even in Chinese mode")
    XCTAssertThrowsError(try KeyboardEngine.ensureInputSchema(setup.engine)) { error in
      guard case KeyboardEngine.InputSessionError.noUsableSchema = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  /// Tapping a candidate commits it: the composition is gone afterwards, which is what the bar shows by
  /// showing no candidate at all.
  func testTappingACandidateTakesIt() throws {
    try deployBundledProfile()
    let controller = booted()
    try type(["n", "i", "h", "a", "o"], in: controller)
    let bar = try bar(controller)

    let cell = try XCTUnwrap(descendants(UIButton.self, in: bar).first {
      isVisible($0, in: bar) && $0.attributedTitle(for: .normal)?.string.contains("你好") == true
    }, "no visible cell for 你好")
    cell.sendActions(for: .touchUpInside)

    let after = visibleTitles(in: bar)
    XCTAssertFalse(after.contains { $0.contains("你好") },
                   "the candidate is still on the bar after being taken: " + after.joined(separator: " | "))
  }

  /// The expand button opens the panel, which then shows the candidates the bar had.
  func testTheExpandButtonOpensThePanel() throws {
    try deployBundledProfile()
    let controller = booted()
    try type(["n", "i", "h", "a", "o"], in: controller)
    let bar = try bar(controller)
    let panel = try panel(controller)
    XCTAssertTrue(panel.isHidden, "the panel is visible before it is asked for")
    let keyboardHeight = try XCTUnwrap(controller.view.constraints.first {
      $0.firstAttribute == .height && $0.secondItem == nil
    }).constant

    let expand = try XCTUnwrap(descendants(UIButton.self, in: bar).first {
      $0.accessibilityLabel == "展开候选面板"
    })
    bar.layoutIfNeeded()
    XCTAssertGreaterThanOrEqual(expand.bounds.width, 44)
    let tap = expand.convert(CGPoint(x: 2, y: expand.bounds.midY), to: bar)
    XCTAssertTrue(bar.hitTest(tap, with: nil) === expand)
    expand.sendActions(for: .touchUpInside)

    XCTAssertFalse(panel.isHidden, "the expand button did not open the panel")
    XCTAssertEqual(controller.view.constraints.first {
      $0.firstAttribute == .height && $0.secondItem == nil
    }?.constant, keyboardHeight, "expanding candidates resized the keyboard")
    XCTAssertTrue(bar.isHidden, "the expanded panel replaces the collapsed candidate row")
    controller.view.layoutIfNeeded()
    waitForPanelCandidates(panel)
    XCTAssertEqual(panel.frame.minY, bar.frame.minY, accuracy: 0.5)
    XCTAssertTrue(texts(in: bar).contains { $0.contains("你好") })
    let panelScroll = panel.subviews.compactMap { $0 as? UIScrollView }.first
    XCTAssertTrue(texts(in: panel).contains { $0.contains("你") },
                  "the continuation shows: " + texts(in: panel).joined(separator: " | ")
                    + " panel=" + String(describing: panel.frame)
                    + " scroll=" + String(describing: panelScroll?.frame)
                    + " content=" + String(describing: panelScroll?.contentSize))
    XCTAssertEqual(expand.accessibilityLabel, "收起候选面板")
  }

  func testSelectingFromExpandedPanelClosesIt() throws {
    try deployBundledProfile()
    let controller = booted()
    try type(["n", "i", "h", "a", "o"], in: controller)
    let bar = try bar(controller)
    bar.onExpand?()
    let panel = try panel(controller)
    waitForPanelCandidates(panel)
    let cell = try XCTUnwrap(descendants(UIButton.self, in: panel).first {
      !$0.isHidden && $0.title(for: .normal) != nil
    })
    cell.sendActions(for: .touchUpInside)
    XCTAssertTrue(panel.isHidden)
    XCTAssertFalse(bar.isHidden)
    XCTAssertEqual(descendants(UIButton.self, in: bar).first {
      $0.accessibilityLabel == "展开候选面板"
    }?.accessibilityLabel, "展开候选面板")
  }
}
