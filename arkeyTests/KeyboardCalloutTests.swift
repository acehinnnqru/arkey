import XCTest
import UIKit
import RimeEngine

/// S3-AC4's callout at the layer only a view can answer.
///
/// The policy is engine-tested — which key raises a callout, how tall it is on the first row, that its frame
/// never leaves the keyboard. What nothing covered is the wiring: a touch on a real key reaching the grid's
/// closure, the controller placing the view, the finger moving it, and letting go hiding it.
///
/// The first run of this test found a real defect. The grid documents its touch points as being in the
/// **grid's** coordinates, and the controller converts them from there; the button was passing its own
/// local centre, so the callout was placed a whole key to the left of the finger.
final class KeyboardCalloutTests: XCTestCase {
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

  private func callout(_ controller: KeyboardViewController) throws -> KeyCalloutView {
    try XCTUnwrap(descendants(KeyCalloutView.self, in: controller.view).first, "the controller has no callout")
  }

  /// The button is what a finger lands on, so the test drives the button's own closure: that is the path the
  /// touch takes, and the point it passes is the button's (the grid converts it).
  private func key(_ character: String,
                   in controller: KeyboardViewController) throws -> (KeyButton, KeyboardKeyGrid) {
    let grid = try XCTUnwrap(descendants(KeyboardKeyGrid.self, in: controller.view).first, "no key grid")
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    let buttons = grid.subviews.compactMap { $0 as? KeyButton }
    let button = try XCTUnwrap(buttons.first { $0.key == .character(character) }, "no " + character + " key")
    return (button, grid)
  }

  func testTheCalloutAppearsOverTheKeyAndFollowsIt() throws {
    let controller = booted()
    let callout = try callout(controller)
    XCTAssertFalse(callout.isShowing, "the callout is visible before any touch")

    let (g, grid) = try key("g", in: controller)
    let local = CGPoint(x: g.bounds.midX, y: g.bounds.midY)
    let finger = grid.convert(local, from: g)
    g.onTouchDown?(local)

    XCTAssertTrue(callout.isShowing, "the callout did not appear for a letter key")
    XCTAssertEqual(callout.frame.midX, finger.x, accuracy: 2,
                   "the callout is not over the key: " + callout.frame.debugDescription)
    XCTAssertTrue(controller.view.bounds.contains(callout.frame),
                  "the callout escaped the keyboard: " + callout.frame.debugDescription)
    XCTAssertEqual(descendants(UILabel.self, in: callout).first?.text, "g",
                   "the callout does not show the key it magnifies")

    // A finger that slides right takes the callout with it, in the same coordinate space.
    let slid = CGPoint(x: local.x + 12, y: local.y)
    g.onTouchMove?(slid)
    XCTAssertEqual(callout.frame.midX, finger.x + 12, accuracy: 2,
                   "the callout did not follow the finger: " + callout.frame.debugDescription)

    g.onTouchEnded?()
    XCTAssertFalse(callout.isShowing, "the callout stayed after the finger lifted")
  }

  /// Where the frame must never go, whatever the finger does: outside the keyboard. The extension cannot draw
  /// beyond its own view, and a callout that tried would be clipped or move the keyboard.
  func testTheCalloutStaysInsideTheKeyboardAtTheEdges() throws {
    let controller = booted()
    let callout = try callout(controller)
    let (a, _) = try key("a", in: controller)
    a.onTouchDown?(CGPoint(x: a.bounds.midX, y: a.bounds.midY))
    XCTAssertTrue(callout.isShowing, "the callout did not appear")

    for x in [-200, -1, 431, 900] as [CGFloat] {
      a.onTouchMove?(CGPoint(x: x, y: a.bounds.midY))
      XCTAssertTrue(controller.view.bounds.contains(callout.frame),
                    "the callout left the keyboard at x=" + String(describing: x) + ": "
                      + callout.frame.debugDescription)
    }
    a.onTouchEnded?()
  }
}
