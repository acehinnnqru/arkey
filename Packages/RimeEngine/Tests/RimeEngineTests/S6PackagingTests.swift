import XCTest
@testable import RimeEngine

/// S1 and S6: the declarations that ship with the bundle. Nothing here can be type-checked — an app group that
/// does not match its entitlement, or an extension that does not ask for Full Access, fails on a device in ways
/// that look like the keyboard being broken. The files are in the repository, so the invariants can be read.
final class S6PackagingTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func plist(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
    let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(parsed as? [String: Any], path + " is not a plist dictionary")
  }

  /// S6 §7: CI runs what a runner can run — the same chain this machine runs, plus an unsigned Release
  /// build for the bundle check and the network-only page check — and it must not pretend to run the
  /// parts that need a device.
  func testTheCIWorkflowRunsTheChainAndOnlyWhatARunnerCanRun() throws {
    let url = repositoryRoot.appendingPathComponent(".github/workflows/verify.yml")
    let text = try String(contentsOf: url, encoding: .utf8)

    XCTAssertTrue(text.contains("./scripts/verify-all.sh"),
                  "CI should run the one command this machine runs")
    XCTAssertTrue(text.contains("check-release-bundle.sh"),
                  "the bundle half needs a build of its own")
    XCTAssertTrue(text.contains("CODE_SIGNING_ALLOWED=NO"),
                  "the bundle check is about an unsigned build")
    XCTAssertTrue(text.contains("check-catalog-pages.sh"),
                  "the page check needs the network, so it is its own step")
    XCTAssertTrue(text.contains("check-verification-scripts.sh"),
                  "the checks are checked too: each must fail when its subject is broken")
    XCTAssertFalse(text.contains("xcodebuild test"),
                   "the iOS test target is S6-AC2 and does not exist yet: CI must not claim to run it")
    XCTAssertFalse(text.contains("scripts/device"),
                   "device work is a written checklist, not a job")
  }

  /// The app group has to be one string, everywhere: two entitlements grant it and four Swift files name it.
  /// A rename that misses one of the six leaves the keyboard without Full Access — which looks like the
  /// keyboard ignoring every setting rather than like a string mismatch.
  func testTheAppGroupIsTheSameStringInEveryDeclaration() throws {
    let appGroups = try plist("arkey/arkey.entitlements")["com.apple.security.application-groups"] as? [String]
    let extensionGroups = try plist("ARKeyboard/ARKeyboard.entitlements")["com.apple.security.application-groups"] as? [String]
    let app = try XCTUnwrap(appGroups?.first, "the app declares no app group")
    let keyboard = try XCTUnwrap(extensionGroups?.first, "the extension declares no app group")
    XCTAssertEqual(app, keyboard, "the two targets must share one group")

    let named = ["arkey/RimeAppModel.swift", "arkey/ProbeLogLocation.swift",
                 "arkey/LaunchProbe.swift", "ARKeyboard/KeyboardEngine.swift"]
    for file in named {
      let text = try String(contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
      XCTAssertTrue(text.contains(app), file + " does not name the app group " + app)
    }
  }

  /// The extension has to ask for open access, or the user cannot switch Full Access on and the lease, the
  /// probe log and the shared settings all silently stop working (S1 §9, S5 §3.2).
  func testTheExtensionAsksForOpenAccessAndIsAKeyboard() throws {
    let manifest = try plist("ARKeyboard/Info.plist")
    let extensionDict = try XCTUnwrap(manifest["NSExtension"] as? [String: Any], "no NSExtension")
    XCTAssertEqual(extensionDict["NSExtensionPointIdentifier"] as? String, "com.apple.keyboard-service")
    let attributes = try XCTUnwrap(extensionDict["NSExtensionAttributes"] as? [String: Any])
    XCTAssertEqual(attributes["RequestsOpenAccess"] as? Bool, true, "Full Access must be requested")
    XCTAssertEqual(attributes["IsASCIICapable"] as? Bool, true)
    XCTAssertEqual(attributes["PrimaryLanguage"] as? String, "zh-Hans")
    let principal = try XCTUnwrap(extensionDict["NSExtensionPrincipalClass"] as? String)
    XCTAssertTrue(principal.hasSuffix(".KeyboardViewController"), principal)
  }
}
