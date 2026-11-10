import XCTest

/// The folding every screen's message goes through.
///
/// S1 §9's rule is that a failure names the repair; a container path names nothing a user can act on, and one
/// reached the UI alongside a missing profile source error.
final class UserFacingTests: XCTestCase {
  func testAbsolutePathsAreFoldedAway() {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("Containers/Data/Application/fixture/Library", isDirectory: true)
    let raw = "部署失败：the profile has no sources at "
      + container.path + "/Application Support/rime/profiles//source"
    let shown = UserFacing.text(raw)
    XCTAssertFalse(shown.contains(container.path), "the path survived: " + shown)
    XCTAssertFalse(shown.contains("Containers"), "part of the path survived: " + shown)
    XCTAssertTrue(shown.hasPrefix("部署失败：the profile has no sources at"),
                  "the sentence was lost: " + shown)
    XCTAssertTrue(shown.contains("profiles"),
                  "the part that says which folder it is was lost: " + shown)
  }

  /// A config key has one slash and is not a path: it is the thing the user has to go and change.
  func testConfigKeysSurvive() {
    for raw in ["写入设置失败：translator/enable_user_dict", "patch: schema_list/0", "全角/半角"] {
      XCTAssertEqual(UserFacing.text(raw), raw, "a config key was folded as if it were a path")
    }
  }

  func testARealMessageIsUnchanged() {
    let raw = "没有可部署的配置。"
    XCTAssertEqual(UserFacing.text(raw), raw)
    XCTAssertEqual(UserFacing.text(""), "")
  }
}
