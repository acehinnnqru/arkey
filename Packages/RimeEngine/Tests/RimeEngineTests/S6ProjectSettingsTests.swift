import XCTest
@testable import RimeEngine

/// The project file carries decisions no compiler checks: which system the targets run on, how the two bundle
/// identifiers relate, and whether a target is signed with the entitlements that grant the app group. All of it
/// is readable text.
final class S6ProjectSettingsTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func project() throws -> String {
    try String(contentsOf: repositoryRoot.appendingPathComponent("arkey.xcodeproj/project.pbxproj"),
               encoding: .utf8)
  }

  /// D4 in docs/tracer-bullet.md is the recorded decision: the app *and* the extension target iOS 18.6, while the
  /// SwiftPM package keeps a lower floor so the engine stays reusable. Found by this test: the extension was on
  /// 26.5, which would install the app on a phone where its keyboard could never appear.
  func testTheTwoTargetsShareOneDeploymentTargetAndThePackageStaysLower() throws {
    let text = try project()
    let values = Set(text.components(separatedBy: "IPHONEOS_DEPLOYMENT_TARGET = ").dropFirst().map { part in
      String(part.prefix { $0 != ";" })
    })
    XCTAssertEqual(values, ["18.6"], "one deployment target for both targets, as D4 records")

    let manifest = try String(contentsOf: repositoryRoot.appendingPathComponent("Packages/RimeEngine/Package.swift"),
                              encoding: .utf8)
    XCTAssertTrue(manifest.contains(".iOS(.v16)"), "the engine keeps its lower floor")
  }

  /// The extension is the app's bundle identifier plus a suffix, which is what App Store validation expects.
  func testTheExtensionIsABundleOfTheApp() throws {
    let text = try project()
    XCTAssertTrue(text.contains("PRODUCT_BUNDLE_IDENTIFIER = com.acehinnnqru.arkey;"))
    XCTAssertTrue(text.contains("PRODUCT_BUNDLE_IDENTIFIER = com.acehinnnqru.arkey.ARKeyboard;"))
  }

  /// An entitlements file that no target signs with grants nothing: the app group would be missing at runtime and
  /// the keyboard would lose Full Access with no build error to explain it.
  func testBothTargetsSignWithTheirEntitlements() throws {
    let text = try project()
    for path in ["arkey/arkey.entitlements", "ARKeyboard/ARKeyboard.entitlements"] {
      XCTAssertTrue(text.contains("CODE_SIGN_ENTITLEMENTS = " + path + ";"), path + " is not wired to a target")
      XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(path).path),
                    path + " does not exist")
    }
  }

  /// The type-check script compiles with one Swift language mode hardcoded; the project sets another per target.
  /// If they ever disagree, "no type errors" becomes a claim about a different language mode than the one the
  /// app is built in — the same class of mistake as a source set the script does not look at.
  func testTheTypeCheckUsesTheLanguageModeTheProjectBuildsWith() throws {
    let text = try project()
    let modes = Set(text.components(separatedBy: "SWIFT_VERSION = ").dropFirst().map { part in
      String(part.prefix { $0 != ";" })
    })
    XCTAssertEqual(modes.count, 1, "one language mode for every target: " + modes.sorted().joined(separator: ", "))
    let mode = try XCTUnwrap(modes.first)

    let script = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/typecheck-app.sh"),
                            encoding: .utf8)
    let checked = try XCTUnwrap(script.range(of: "-swift-version ").map { range in
      String(script[range.upperBound...].prefix { $0 != " " && $0 != "\\" && $0 != "\n" })
    }, "the type-check script names no Swift version")
    XCTAssertEqual(Double(checked), Double(mode),
                   "the script checks " + checked + " but the project builds " + mode)
  }

  /// S1-AC6's install half is engine code (`RimeLocalDataInstaller`); its build half is this phase: a
  /// Debug build copies a gitignored `RimeData.local/` into the bundle, and a Release build must not —
  /// the release check refuses the name, so the guard inside the script is the first of two locks.
  func testDebugBuildsCopyALocalConfigAndReleaseBuildsNeverDo() throws {
    let text = try project()

    let marker = "/* Copy RimeData.local (Debug) */ = {"
    let raw = try XCTUnwrap(text.split(separator: "\n").first { $0.contains(marker) },
                            "no shell-script phase copies RimeData.local into the bundle")
    let line = String(raw).trimmingCharacters(in: .whitespaces)
    let id = try XCTUnwrap(line.components(separatedBy: " ").first)
    XCTAssertTrue(id.hasPrefix("A5C0DE"), "phase ids of ours are namespaced: " + id)

    let phase = try XCTUnwrap(text.range(of: marker).map { range in
      String(text[range.lowerBound...].prefix(1600))
    })
    XCTAssertTrue(phase.contains("PBXShellScriptBuildPhase"), "it has to be a script phase")
    XCTAssertTrue(phase.contains("${CONFIGURATION}"), "the phase cannot tell Debug from Release without it")
    XCTAssertTrue(phase.contains("Debug"), "the guard names the configuration it copies for")
    // Order matters more than the exact text: the guard has to run before the copy, which is what
    // keeps a Release build from ever putting the directory in the bundle.
    let guardIndex = try XCTUnwrap(phase.range(of: "CONFIGURATION")).lowerBound
    let copyIndex = try XCTUnwrap(phase.range(of: "cp -R")).lowerBound
    XCTAssertLessThan(guardIndex, copyIndex, "the Release guard has to come before the copy")
    XCTAssertTrue(phase.contains("UNLOCALIZED_RESOURCES_FOLDER_PATH"),
                  "the copy has to land inside the app bundle, not next to it")
    XCTAssertTrue(phase.contains("cp -R"), "and it has to be a copy")

    // The app target has to run it: a phase no target lists is never executed.
    let anchor = try XCTUnwrap(text.range(of: "name = arkey;"))
    let objectStart = text.index(anchor.lowerBound, offsetBy: -1500, limitedBy: text.startIndex) ?? text.startIndex
    XCTAssertTrue(text[objectStart..<anchor.lowerBound].contains(id),
                  "the arkey target does not run the phase: " + id)
  }

  /// Both targets generate their Info.plist, and the extension also starts from a file: that combination is what
  /// merges the generated keys into the hand-written one, so the file it names has to exist.
  func testTheInfoPlistArrangementIsCoherent() throws {
    let text = try project()
    let generated = text.components(separatedBy: "GENERATE_INFOPLIST_FILE = ").dropFirst().filter { $0.hasPrefix("YES") }
    XCTAssertEqual(generated.count, 4, "four build configurations generate their Info.plist")

    // Line-anchored: "GENERATE_INFOPLIST_FILE = YES;" contains "INFOPLIST_FILE = " as a substring, and a split on
    // the bare prefix collects "YES" as if it were a path — which is what this test did on its first run.
    let named = text.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("INFOPLIST_FILE = ") }
      .map { String($0.dropFirst("INFOPLIST_FILE = ".count).prefix { $0 != ";" }) }
    XCTAssertFalse(named.isEmpty, "the extension names its own Info.plist")
    for path in Set(named) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(path).path),
                    path + " is named by the project but does not exist")
    }
  }
}
