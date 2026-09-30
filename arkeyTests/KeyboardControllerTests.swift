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
  /// A controller with a keyboard-shaped view: 430 pt wide, the measured width, and tall enough for the
  /// candidate bar, the rows and the bottom inset the constraints ask for. Off a window nothing lays itself
  /// out, so the test gives it the size the system would give it on a phone.
  private func booted() -> KeyboardViewController {
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
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
}
