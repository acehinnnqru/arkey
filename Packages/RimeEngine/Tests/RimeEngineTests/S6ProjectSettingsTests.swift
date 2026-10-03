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

  /// S6 §4's document type: a config archive downloaded from the project page has to be openable in
  /// the app from Safari or Files. The app target names an Info.plist for exactly that, and the rank is
  /// Alternate so the system keeps its own zip handler.
  func testTheAppDeclaresTheArchiveTypeItCanImport() throws {
    let text = try project()
    XCTAssertTrue(text.contains("INFOPLIST_FILE = arkey/Info.plist;"),
                  "the app target does not name the plist that carries the document type")

    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("arkey/Info.plist"))
    let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil)
      as? [String: Any], "arkey/Info.plist is not a plist dictionary")
    let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]],
                              "no CFBundleDocumentTypes")
    let archive = try XCTUnwrap(types.first { entry in
      (entry["LSItemContentTypes"] as? [String])?.contains("public.zip-archive") == true
    }, "no entry claims the zip archive type the importer accepts")
    XCTAssertEqual(archive["LSHandlerRank"] as? String, "Alternate",
                   "the system's own zip handler must stay the default")
    XCTAssertEqual(archive["CFBundleTypeRole"] as? String, "Viewer")
  }

  /// Round 190: the importer's picker could not see a single file this app had written, and the simulator
  /// says why in one line — "On My iPhone is Empty". Files lists an app's own folder only when the app asks
  /// for it, so without this key 配置库's export, and the sync folder beside it, are unreachable from the
  /// importer that is supposed to take them back (S2 §7's round trip through Files, S5's transport).
  func testTheAppsOwnDocumentsFolderIsBrowsable() throws {
    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("arkey/Info.plist"))
    let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil)
      as? [String: Any], "arkey/Info.plist is not a plist dictionary")
    XCTAssertEqual(plist["UIFileSharingEnabled"] as? Bool, true,
                   "without file sharing the picker cannot browse the folder the app exports into")
    XCTAssertEqual(plist["LSSupportsOpeningDocumentsInPlace"] as? Bool, true,
                   "and without this one a chosen document is copied instead of opened where it lies")
  }

  /// S6 §2.1: the Xcode project gains one test target for the app — the layer that runs on the
  /// simulator, where UIKit is real and the views lay out for a screen. Nothing here can run it (no
  /// xcodebuild in this sandbox), so what this test can do is check that the target is wired the way a
  /// unit-test bundle has to be: hosted by the app, loading its binary, depending on it, and carrying
  /// the app's own deployment target.
  func testTheTestTargetIsWiredToTheAppAsAUnitTestBundle() throws {
    let text = try project()
    XCTAssertTrue(text.contains("productType = \"com.apple.product-type.bundle.unit-test\";"),
                  "no unit-test bundle in the project")
    XCTAssertTrue(text.contains("TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/arkey.app/"
                  + "$(BUNDLE_EXECUTABLE_FOLDER_PATH)/arkey\";"),
                  "the test bundle has no host, so it cannot see the app's code or run on the simulator")
    XCTAssertTrue(text.contains("BUNDLE_LOADER = \"$(TEST_HOST)\";"),
                  "without the loader the test bundle does not link against the app")
    XCTAssertTrue(text.contains("TestTargetID = 1B05164E3062E34E00EDD6AE;"),
                  "the target attributes do not point the test bundle at the app")
    XCTAssertTrue(text.contains("path = arkeyTests;"), "the test sources are not in the project")
    let count = try FileManager.default.contentsOfDirectory(
      at: repositoryRoot.appendingPathComponent("arkeyTests"),
      includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }.count
    XCTAssertGreaterThan(count, 0, "the test target has no sources to build")
  }

  /// The scheme is what `xcodebuild test` runs: a target the scheme does not name is a target that
  /// never runs, and a rename that misses the scheme breaks `test` without breaking `build`. The
  /// scheme has to be in `xcshareddata` for a fresh clone to see it at all.
  func testTheSharedSchemeRunsTheTestTarget() throws {
    let scheme = repositoryRoot.appendingPathComponent(
      "arkey.xcodeproj/xcshareddata/xcschemes/arkey.xcscheme")
    XCTAssertTrue(FileManager.default.fileExists(atPath: scheme.path),
                  "the scheme is not shared, so a fresh clone cannot run the tests")
    let text = try String(contentsOf: scheme, encoding: .utf8)

    XCTAssertTrue(text.contains("BlueprintIdentifier = \"A5C0DE000000000000000010\""),
                  "the scheme does not name the test target's id")
    XCTAssertTrue(text.contains("BuildableName = \"arkeyTests.xctest\""),
                  "the scheme does not build the test bundle")
    XCTAssertTrue(try project().contains("A5C0DE000000000000000010 /* arkeyTests */"),
                  "the scheme's id is not a target in the project file")
    XCTAssertTrue(text.contains("container:arkey.xcodeproj"),
                  "the scheme points at some other project")
  }

  /// Both targets generate their Info.plist, and the extension also starts from a file: that combination is what
  /// merges the generated keys into the hand-written one, so the file it names has to exist.
  func testTheInfoPlistArrangementIsCoherent() throws {
    let text = try project()
    let generated = text.components(separatedBy: "GENERATE_INFOPLIST_FILE = ").dropFirst().filter { $0.hasPrefix("YES") }
    XCTAssertEqual(generated.count, 8,
                   "eight build configurations generate their Info.plist: the app, the extension, the unit-test "
                     + "bundle and the UI-test bundle, in Debug and Release")

    let named = namedInfoPlists(in: text)
    XCTAssertFalse(named.isEmpty, "the extension names its own Info.plist")
    for path in named {
      XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(path).path),
                    path + " is named by the project but does not exist")
    }
  }

  /// A synchronized folder copies what is in it into its target unless the file is excepted, and a file the
  /// project names as `INFOPLIST_FILE` is written into the bundle by the Info.plist step as well. With both,
  /// the build stops at "Multiple commands produce .../arkey.app/Info.plist" — which no type-check, no test on
  /// the Mac and no reading of the settings can see. The extension's folder was excepted from the start; the
  /// app's was not, and the first `xcodebuild test` run on a simulator could not build at all until it was
  /// (round 141). Removing the exception makes this test the thing that fails instead.
  func testASynchronizedFolderDoesNotAlsoCopyTheInfoPlistItsTargetNames() throws {
    let text = try project()
    let folders = synchronizedFolders(in: text)
    XCTAssertTrue(folders.contains("arkey"), "the app's sources are a synchronized folder")

    for path in namedInfoPlists(in: text) {
      let folder = (path as NSString).deletingLastPathComponent
      guard folders.contains(folder) else { continue }
      let name = (path as NSString).lastPathComponent
      let exception = exceptionSet(forFolder: folder, in: text)
      XCTAssertNotNil(exception,
                      folder + " is a synchronized folder, so it copies " + path + " into the bundle as well "
                        + "as the Info.plist step does, and the build refuses to run")
      XCTAssertTrue(exception?.contains(name + ",") == true,
                    "the exception for " + folder + " does not exclude " + path)
    }
  }

  /// The golden fixture is the one thing the iOS golden test needs from outside its own sources, and a resource
  /// that misses the bundle fails at runtime rather than at build time. The test target's Resources phase has to
  /// carry the path the package's own test reads — `RimeKeyboardGolden.fixtureName`, so the two cannot disagree
  /// about the name — and the file has to be there.
  func testTheGoldenFixtureReachesTheTestBundle() throws {
    let text = try project()
    let path = "Packages/RimeEngine/Tests/Golden/" + RimeKeyboardGolden.fixtureName
    XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(path).path),
                  path + " does not exist")

    // The chain has to be walked, not glanced at: a build file that no phase lists, or a phase that no target
    // builds, leaves the fixture out of the bundle while every file name still reads correctly. The first
    // version of this test looked for the words "KeyboardLayout.txt in Resources" and passed with the phase
    // emptied (round 142) — the same orphan-shaped hole the exception-set test had.
    let reference = try objectID(withPath: path, in: text)
    let buildFile = try objectID(ofBuildFileReferencing: reference, in: text)
    let phase = try objectID(ofResourcesPhaseIn: testTargetBlock(in: text))
    XCTAssertTrue(try block(forObjectID: phase, in: text).contains(buildFile),
                  "the test target's Resources phase does not carry the golden fixture")
  }

  /// `@testable import` needs testability on the importing file as well as on the module it imports. The project
  /// enables it for Debug — the configuration the test action builds — and the hand-written type-check has to
  /// pass the same flag, or the check rejects code the build accepts. The same class of divergence as the Swift
  /// language mode above, and it was found the same way: by the check refusing a file the build compiles.
  func testTheTestTargetIsTypeCheckedWithTestability() throws {
    let script = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/typecheck-app.sh"),
                            encoding: .utf8)
    XCTAssertTrue(script.contains("check \"tests\" -enable-testing"),
                  "the iOS test sources are type-checked without testability")
    XCTAssertTrue(try project().contains("ENABLE_TESTABILITY = YES;"),
                  "the project does not enable testability for Debug builds")
  }

  // MARK: - Reading the project file

  /// The arkeyTests target's own object, bounded at its closing brace.
  private func testTargetBlock(in text: String) throws -> String {
    let start = try XCTUnwrap(text.range(of: "A5C0DE000000000000000010 /* arkeyTests */ = {"))
    let end = try XCTUnwrap(text.range(of: "\n\t\t};", range: start.upperBound..<text.endIndex))
    return String(text[start.upperBound..<end.lowerBound])
  }

  private func firstIdentifier(in line: Substring) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let identifier = String(trimmed.prefix(24))
    return identifier.count == 24 ? identifier : nil
  }

  /// The object that names a path — the fixture's file reference.
  private func objectID(withPath path: String, in text: String) throws -> String {
    let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("path = " + path + ";") },
                             "no object in the project names " + path)
    return try XCTUnwrap(firstIdentifier(in: line))
  }

  private func objectID(ofBuildFileReferencing reference: String, in text: String) throws -> String {
    let line = try XCTUnwrap(text.split(separator: "\n").first {
      $0.contains("isa = PBXBuildFile") && $0.contains("fileRef = " + reference + " ")
    }, "no build file references " + reference)
    return try XCTUnwrap(firstIdentifier(in: line))
  }

  private func objectID(ofResourcesPhaseIn targetBlock: String) throws -> String {
    let line = try XCTUnwrap(targetBlock.split(separator: "\n").first { $0.contains("/* Resources */,") },
                             "the target builds no Resources phase")
    return try XCTUnwrap(firstIdentifier(in: line))
  }

  /// An object's own definition — two tabs of indentation, so a reference to it elsewhere does not match.
  private func block(forObjectID id: String, in text: String) throws -> String {
    let start = try XCTUnwrap(text.range(of: "\n\t\t" + id + " "))
    let end = try XCTUnwrap(text.range(of: "\n\t\t};", range: start.upperBound..<text.endIndex))
    return String(text[start.upperBound..<end.lowerBound])
  }

  /// Line-anchored: "GENERATE_INFOPLIST_FILE = YES;" contains "INFOPLIST_FILE = " as a substring, and a split
  /// on the bare prefix collects "YES" as if it were a path — which is what the arrangement test did on its
  /// first run.
  private func namedInfoPlists(in text: String) -> Set<String> {
    Set(text.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("INFOPLIST_FILE = ") }
      .map { String($0.dropFirst("INFOPLIST_FILE = ".count).prefix { $0 != ";" }) })
  }

  private func synchronizedFolders(in text: String) -> Set<String> {
    Set(text.components(separatedBy: "isa = PBXFileSystemSynchronizedRootGroup;").dropFirst().compactMap { block in
      guard let range = block.range(of: "path = ") else { return nil }
      return String(block[range.upperBound...].prefix { $0 != ";" })
    })
  }

  /// One synchronized folder's own object, bounded at its closing brace.
  private func synchronizedFolderBlock(_ folder: String, in text: String) -> String? {
    for block in text.components(separatedBy: "isa = PBXFileSystemSynchronizedRootGroup;").dropFirst() {
      guard let bounded = block.range(of: "\n\t\t};").map({ String(block[..<$0.lowerBound]) }) ?? Optional(block),
            let pathRange = bounded.range(of: "path = ") else { continue }
      if String(bounded[pathRange.upperBound...].prefix { $0 != ";" }) == folder { return bounded }
    }
    return nil
  }

  /// The body of the exception set the folder's **own object** points at — not just any exception set in the
  /// file: a set nothing references is an exception that does not apply, which is exactly the state this test
  /// first missed when it searched the whole file for the marker (round 141).
  private func exceptionSet(forFolder folder: String, in text: String) -> String? {
    let marker = "/* Exceptions for " + quote + folder + quote + " folder in "
    guard let block = synchronizedFolderBlock(folder, in: text), let reference = block.range(of: marker) else {
      return nil
    }
    let id = String(block[..<reference.lowerBound].suffix(24))
    guard let start = text.range(of: "/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */"),
          let end = text.range(of: "/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */") else {
      return nil
    }
    let section = text[start.upperBound..<end.lowerBound]
    guard let object = section.range(of: id) else { return nil }
    let rest = section[object.upperBound...]
    guard let close = rest.range(of: "\n\t\t};") else { return nil }
    return String(rest[..<close.lowerBound])
  }

  private var quote: String { String(UnicodeScalar(34)) }

  /// D3 and S6 §6: v1 is specified as iPhone portrait, the name the home screen and the keyboard list show is the
  /// product's name, and an App Store upload asks the export-compliance question unless the plist answers it.
  /// All three were wrong in the built plist: landscape was allowed on both idioms (a layout no capture covers),
  /// the app had no display name at all so it defaulted to the target's lower-case "arkey", and the extension
  /// said "ARKeyboard".
  func testTheBuiltPlistSaysPortraitArkeyAndNoCustomEncryption() throws {
    let text = try project()
    XCTAssertTrue(text.contains("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = UIInterfaceOrientationPortrait;"),
                  "the app allows more than portrait on iPhone, which D3 does not cover")
    XCTAssertFalse(text.contains("UIInterfaceOrientationLandscape"),
                   "a landscape orientation is declared somewhere in the project")
    XCTAssertEqual(text.components(separatedBy: "INFOPLIST_KEY_CFBundleDisplayName = Arkey;").count - 1, 4,
                   "the app and the extension, in both configurations, should each say Arkey")
    XCTAssertFalse(text.contains("INFOPLIST_KEY_CFBundleDisplayName = ARKeyboard;"),
                   "a display name still uses the target's name instead of the product's")

    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("arkey/Info.plist"))
    let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil)
                              as? [String: Any], "arkey/Info.plist is not a plist dictionary")
    XCTAssertEqual(plist["ITSAppUsesNonExemptEncryption"] as? Bool, false,
                   "the export-compliance answer is missing or says the app uses non-exempt encryption")
  }

  /// The app's interface is Chinese, its keyboard declares zh-Hans, and the project said English — which is what
  /// the store listing and the app's language in Settings would have shown.
  func testTheAppAndItsKeyboardAgreeThatTheyAreChinese() throws {
    let text = try project()
    XCTAssertTrue(text.contains("developmentRegion = \"zh-Hans\";"),
                  "the project's development region is not the language its interface is written in")
    XCTAssertTrue(text.contains("\"zh-Hans\",") || text.contains("zh-Hans,"),
                  "zh-Hans is not among the project's known regions")

    let appPlist = try XCTUnwrap(try PropertyListSerialization.propertyList(
      from: Data(contentsOf: repositoryRoot.appendingPathComponent("arkey/Info.plist")), format: nil)
      as? [String: Any], "arkey/Info.plist is not a plist dictionary")
    XCTAssertEqual(appPlist["CFBundleLocalizations"] as? [String], ["zh-Hans"],
                   "the app does not declare the language it is written in")

    let extensionPlist = try XCTUnwrap(try PropertyListSerialization.propertyList(
      from: Data(contentsOf: repositoryRoot.appendingPathComponent("ARKeyboard/Info.plist")), format: nil)
      as? [String: Any], "ARKeyboard/Info.plist is not a plist dictionary")
    let extensionAttributes = (extensionPlist["NSExtension"] as? [String: Any])?["NSExtensionAttributes"]
      as? [String: Any]
    XCTAssertEqual(extensionAttributes?["PrimaryLanguage"] as? String, "zh-Hans",
                   "the keyboard's declared language is not the app's")
    XCTAssertEqual(extensionAttributes?["IsASCIICapable"] as? Bool, true,
                   "the keyboard types Latin letters, so it is ASCII-capable")
  }
}
