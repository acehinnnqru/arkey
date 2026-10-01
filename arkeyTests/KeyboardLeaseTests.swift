import XCTest
import RimeEngine

/// S5-AC2's missing link: the keyboard's own claim and release, at the view controller.
///
/// The engine side of the lease has been tested since it existed. What was only ever read off the code was that
/// the extension *calls* it — viewWillAppear holding the lease and viewWillDisappear releasing it. The extension
/// is compiled into this bundle, so the controller can be booted and its appearance driven for real, and the
/// lease file read before and after.
@MainActor
final class KeyboardLeaseTests: XCTestCase {
  func testTheKeyboardClaimsTheLeaseAtAppearanceAndReleasesItAtDismissal() throws {
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 420)
    controller.viewWillAppear(false)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    guard case .success(let setup) = KeyboardEngine.setup else {
      return XCTFail("the keyboard did not start")
    }
    let store = RimeLeaseStore(workspace: setup.workspace)

    let held = try XCTUnwrap(store.current(), "the keyboard claims no lease at appearance")
    XCTAssertEqual(held.pid, getpid(), "the lease is not this process's")
    XCTAssertFalse(store.isCold(), "the lease is stale the moment it is claimed")
    // blocker() is the app's gate, and it is the user-visible half of the lease: while the keyboard holds it,
    // the dictionary screen says the keyboard is using the dictionary.
    let access = RimeDictionaryAccess(workspace: setup.workspace, engine: setup.engine, leaseStore: store)
    XCTAssertNotNil(access.blocker(), "the app is not told the dictionary is in use")

    controller.viewWillDisappear(false)

    // Released, not merely stale: the app has to be usable again the moment the keyboard goes away, which is
    // what S5 §3.2 asks for and what the staleness rule alone cannot give it.
    if let after = store.current() {
      XCTAssertEqual(after.pid, getpid(), "another process holds the lease after dismissal")
      XCTAssertTrue(store.isCold(), "the lease is still live after dismissal: " + String(describing: after))
    }
    XCTAssertNil(access.blocker(), "the app still reports the dictionary as in use after dismissal")
  }
}
