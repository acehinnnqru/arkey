import XCTest
import UIKit
import RimeEngine

/// Exercise the control events and the run-loop mode used during a held touch.
final class KeyboardDeleteRepeatTests: XCTestCase {
  private final class Actions: NSObject {
    var times: [Date] = []

    @objc func record() { times.append(Date()) }
  }

  private func deleteKey(actions: Actions) -> KeyButton {
    let key = KeyButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    key.key = .backspace
    key.repeatsWhileHeld = true
    key.addTarget(actions, action: #selector(Actions.record), for: .primaryActionTriggered)
    return key
  }

  private func track(for duration: TimeInterval) {
    let deadline = Date(timeIntervalSinceNow: duration)
    while Date() < deadline {
      RunLoop.main.run(mode: .tracking, before: deadline)
    }
  }

  func testTapDeletesOnPressWithoutAnotherDeleteOnRelease() {
    let actions = Actions()
    let key = deleteKey(actions: actions)
    key.sendActions(for: .touchDown)
    XCTAssertEqual(actions.times.count, 1)
    key.sendActions(for: .touchUpInside)
    track(for: 0.65)
    XCTAssertEqual(actions.times.count, 1)
  }

  func testHoldRepeatsInTouchTrackingModeAtConfiguredCadence() {
    let actions = Actions()
    let key = deleteKey(actions: actions)
    key.sendActions(for: .touchDown)
    track(for: 0.35)
    XCTAssertEqual(actions.times.count, 1, "A brief hold must not start repeating")
    track(for: 0.5)
    XCTAssertGreaterThanOrEqual(actions.times.count, 4)
    if actions.times.count >= 4 {
      XCTAssertEqual(actions.times[1].timeIntervalSince(actions.times[0]), 0.5, accuracy: 0.08)
      XCTAssertEqual(actions.times[2].timeIntervalSince(actions.times[1]), 0.1, accuracy: 0.05)
    }
    key.sendActions(for: .touchUpInside)
    let count = actions.times.count
    track(for: 0.25)
    XCTAssertEqual(actions.times.count, count, "Release must stop without an extra delete")
  }

  func testCancellationAndSlideOffStopRepeatAndAllowANewPress() {
    let actions = Actions()
    let key = deleteKey(actions: actions)
    key.feedback = RimeKeyFeedback(deleteRepeatDelay: 0.05, deleteRepeatInterval: 0.04)
    for event in [UIControl.Event.touchCancel, .touchDragExit, .touchUpOutside] {
      key.sendActions(for: .touchDown)
      track(for: 0.12)
      key.sendActions(for: event)
      let count = actions.times.count
      track(for: 0.12)
      XCTAssertEqual(actions.times.count, count)
    }
    key.sendActions(for: .touchDragEnter)
    let count = actions.times.count
    key.cancelTracking(with: nil)
    track(for: 0.12)
    XCTAssertEqual(actions.times.count, count)
  }

  func testRemovingKeyboardFromWindowStopsRepeat() {
    let actions = Actions()
    let key = deleteKey(actions: actions)
    key.feedback = RimeKeyFeedback(deleteRepeatDelay: 0.05, deleteRepeatInterval: 0.04)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let keyboard = UIView(frame: window.bounds)
    window.addSubview(keyboard)
    keyboard.addSubview(key)
    key.sendActions(for: .touchDown)
    keyboard.removeFromSuperview()
    track(for: 0.12)
    XCTAssertEqual(actions.times.count, 1)
  }

  func testDuplicateTouchDownDoesNotCreateMultipleRepeatTimers() {
    let actions = Actions()
    let key = deleteKey(actions: actions)
    key.sendActions(for: .touchDown)
    key.sendActions(for: .touchDown)
    XCTAssertEqual(actions.times.count, 1)
    key.sendActions(for: .touchCancel)
  }

  func testGridCancelsHeldDeleteBeforeKeyboardDisappears() throws {
    let grid = KeyboardKeyGrid(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
    grid.configure(theme: .current(for: .default), layer: .letters,
                   asciiMode: true, returnKeyLabel: "Return", showsGlobeRow: false,
                   feedback: RimeKeyFeedback(deleteRepeatDelay: 0.05, deleteRepeatInterval: 0.04))
    grid.layoutIfNeeded()
    let key = try XCTUnwrap(grid.subviews.compactMap { $0 as? KeyButton }
      .first { $0.key == .backspace })
    var deletes = 0
    grid.onKey = { if $0 == .backspace { deletes += 1 } }
    key.sendActions(for: .touchDown)
    track(for: 0.12)
    XCTAssertGreaterThan(deletes, 1, "Repeats must reach the grid's input callback")
    grid.cancelActivePresses()
    let count = deletes
    track(for: 0.12)
    XCTAssertEqual(deletes, count)
  }

  func testLetterStillCommitsOnRelease() {
    let actions = Actions()
    let key = KeyButton(frame: .zero)
    key.addTarget(actions, action: #selector(Actions.record), for: .primaryActionTriggered)
    key.sendActions(for: .touchDown)
    XCTAssertTrue(actions.times.isEmpty)
    key.sendActions(for: .touchUpInside)
    XCTAssertEqual(actions.times.count, 1)
  }
}
