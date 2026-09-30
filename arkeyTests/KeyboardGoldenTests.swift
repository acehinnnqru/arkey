import XCTest
@testable import RimeEngine

/// S6-AC2's second half: the **golden snapshot**, compared by a test that runs on a simulator.
///
/// The text comes from `RimeKeyboardGolden` in the engine — the same generator the package's
/// `S3GoldenTests` uses on macOS — and the fixture reaches this bundle as a resource (the project file's
/// Resources phase, pinned by `S6ProjectSettingsTests`). Two targets comparing one generated text is the
/// point: the model the views draw from is checked where the views actually lay out, not only on the Mac.
final class KeyboardGoldenTests: XCTestCase {
  func testTheKeyboardModelMatchesItsGoldenSnapshot() throws {
    let bundle = Bundle(for: KeyboardGoldenTests.self)
    let url = try XCTUnwrap(bundle.url(forResource: "KeyboardLayout", withExtension: "txt"),
                            "the golden fixture is not in the test bundle")
    let golden = try String(contentsOf: url, encoding: .utf8)
    let snapshot = RimeKeyboardGolden.snapshot()

    let expected = golden.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let actual = snapshot.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    XCTAssertFalse(expected.isEmpty, "the fixture is empty, so this comparison proves nothing")
    for index in 0..<max(expected.count, actual.count) {
      let was = index < expected.count ? expected[index] : "(missing)"
      let now = index < actual.count ? actual[index] : "(missing)"
      if was != now {
        return XCTFail("the model drifted from the golden snapshot at line " + String(index + 1)
                       + ":\n  golden: " + was + "\n  now:    " + now)
      }
    }
  }
}
