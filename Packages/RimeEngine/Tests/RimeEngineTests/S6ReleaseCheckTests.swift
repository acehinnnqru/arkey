import XCTest
@testable import RimeEngine

/// S6: the Release bundle check, against synthetic bundles whose every failure is deliberate.
final class S6ReleaseCheckTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL { repositoryRoot.appendingPathComponent("RimeData", isDirectory: true) }

  private var scratch: URL!
  private var bundle: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s6-release", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    bundle = scratch.appendingPathComponent("arkey.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try copyTracerDataIntoBundle()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  /// A bundle that looks like the real one: the app's Resources/RimeData, and the extension's own
  /// copy inside the plugin.
  private func copyTracerDataIntoBundle() throws {
    let fileManager = FileManager.default
    // A real bundle carries its icon and its privacy manifest, and its extension carries its own manifest; the
    // synthetic one has to as well, or every cleanliness assertion here would be testing those rules instead of
    // the one it names.
    try Data("icon".utf8).write(to: bundle.appendingPathComponent("AppIcon60x60@2x.png"))
    try Data("manifest".utf8).write(to: bundle.appendingPathComponent("PrivacyInfo.xcprivacy"))
    let plugin = bundle.appendingPathComponent("PlugIns/ARKeyboard.appex", isDirectory: true)
    try fileManager.createDirectory(at: plugin, withIntermediateDirectories: true)
    try Data("manifest".utf8).write(to: plugin.appendingPathComponent("PrivacyInfo.xcprivacy"))
    let appData = bundle.appendingPathComponent("RimeData", isDirectory: true)
    try fileManager.createDirectory(at: appData, withIntermediateDirectories: true)
    for name in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try fileManager.copyItem(at: tracerData.appendingPathComponent(name),
                               to: appData.appendingPathComponent(name))
    }
    let appBuild = appData.appendingPathComponent("build", isDirectory: true)
    try fileManager.createDirectory(at: appBuild, withIntermediateDirectories: true)
    for name in ["tracer.table.bin", "tracer.prism.bin"] {
      try Data(name.utf8).write(to: appBuild.appendingPathComponent(name))
    }

    let pluginData = bundle.appendingPathComponent("PlugIns/ARKeyboard.appex/RimeData", isDirectory: true)
    try fileManager.createDirectory(at: pluginData, withIntermediateDirectories: true)
    for name in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try fileManager.copyItem(at: tracerData.appendingPathComponent(name),
                               to: pluginData.appendingPathComponent(name))
    }
    let pluginBuild = pluginData.appendingPathComponent("build", isDirectory: true)
    try fileManager.createDirectory(at: pluginBuild, withIntermediateDirectories: true)
    try Data("tracer.table.bin".utf8).write(to: pluginBuild.appendingPathComponent("tracer.table.bin"))

    // The bundle needs the tracer's scanned names to match the repository's digests.
    let repoBuild = appData.appendingPathComponent("build")
    try fileManager.removeItem(at: repoBuild)
    try fileManager.createDirectory(at: repoBuild, withIntermediateDirectories: true)
    for name in ["tracer.table.bin", "tracer.prism.bin", "tracer.reverse.bin", "default.yaml",
                 "tracer.schema.yaml"] {
      let source = tracerData.appendingPathComponent("build/" + name)
      if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.copyItem(at: source, to: repoBuild.appendingPathComponent(name))
      }
    }
    try fileManager.removeItem(at: pluginBuild)
    try fileManager.createDirectory(at: pluginBuild, withIntermediateDirectories: true)
    for name in ["tracer.table.bin", "tracer.prism.bin", "tracer.reverse.bin", "default.yaml",
                 "tracer.schema.yaml"] {
      let source = tracerData.appendingPathComponent("build/" + name)
      if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.copyItem(at: source, to: pluginBuild.appendingPathComponent(name))
      }
    }
  }

  private func check() -> RimeReleaseCheck.Result {
    RimeReleaseCheck.check(bundle: bundle, tracerData: tracerData)
  }

  // MARK: The rules

  /// An app store build needs an icon, and an asset catalog with no images builds without a murmur.
  func testABundleWithNoIconIsAFinding() throws {
    // setUp already built a bundle that looks like the real one, icon included.
    XCTAssertTrue(RimeReleaseCheck.check(bundle: bundle, tracerData: tracerData).isClean,
                  "the fixture itself is not clean, so this test would be measuring something else")

    try FileManager.default.removeItem(at: bundle.appendingPathComponent("AppIcon60x60@2x.png"))
    let result = RimeReleaseCheck.check(bundle: bundle, tracerData: tracerData)
    XCTAssertFalse(result.isClean, "the bundle has no icon and the check did not notice")
    XCTAssertTrue(result.findings.contains { $0.reason.contains("no AppIcon") },
                  result.findings.map { $0.reason }.joined(separator: " | "))
  }

  /// Each bundle is inspected on its own: the extension's manifest is not the app's.
  func testAnExtensionWithoutItsOwnManifestIsAFinding() throws {
    XCTAssertTrue(RimeReleaseCheck.check(bundle: bundle, tracerData: tracerData).isClean,
                  "the fixture itself is not clean, so this test would be measuring something else")

    try FileManager.default.removeItem(
      at: bundle.appendingPathComponent("PlugIns/ARKeyboard.appex/PrivacyInfo.xcprivacy"))
    let result = RimeReleaseCheck.check(bundle: bundle, tracerData: tracerData)
    XCTAssertFalse(result.isClean, "the extension has no manifest and the check did not notice")
    XCTAssertTrue(result.findings.contains { $0.reason.contains("no PrivacyInfo.xcprivacy") },
                  result.findings.map { $0.reason }.joined(separator: " | "))
  }

  func testABundleCarryingOnlyTheTracerDataIsClean() {
    let result = check()
    XCTAssertTrue(result.isClean, result.report)
    XCTAssertEqual(result.dataDirectories.count, 2, "the app and its extension each carry a copy")
    XCTAssertGreaterThan(result.fileCount, 0)
    XCTAssertTrue(result.errors.isEmpty, result.report)
  }

  func testThirdPartyConfigDataIsAFinding() throws {
    try Data("---\nname: rime_ice\n".utf8).write(
      to: bundle.appendingPathComponent("RimeData/rime_ice.dict.yaml"))
    let result = check()
    XCTAssertFalse(result.isClean)
    XCTAssertTrue(result.errors.contains { $0.path.hasSuffix("rime_ice.dict.yaml") }, result.report)
  }

  /// A renamed copy is still a finding: the check is content- and path-based, not name-based.
  func testARenamedThirdPartyFileIsStillAFinding() throws {
    let directory = bundle.appendingPathComponent("RimeData/cn_dicts", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: tracerData.appendingPathComponent("tracer.dict.yaml"),
                                     to: directory.appendingPathComponent("base.dict.yaml"))
    let result = check()
    XCTAssertFalse(result.isClean)
    XCTAssertTrue(result.errors.contains { $0.path.contains("cn_dicts/base.dict.yaml") }, result.report)
  }

  func testContentThatDiffersFromTheTracerDataIsAFinding() throws {
    try Data("changed".utf8).write(to: bundle.appendingPathComponent("RimeData/default.yaml"))
    let result = check()
    XCTAssertFalse(result.isClean)
    XCTAssertTrue(result.errors.contains { $0.path.hasSuffix("default.yaml") }, result.report)
  }

  func testADebugDevelopmentCopyIsAFinding() throws {
    let directory = bundle.appendingPathComponent("RimeData.local", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("someone else's dictionary".utf8).write(to: directory.appendingPathComponent("x.dict.yaml"))
    let result = check()
    XCTAssertFalse(result.isClean)
    XCTAssertTrue(result.errors.contains { $0.path.contains("RimeData.local") }, result.report)
  }

  func testAnImportedProfileOrAUserDictionaryInTheBundleIsAFinding() throws {
    try FileManager.default.createDirectory(
      at: bundle.appendingPathComponent("rime/profiles/rime-ice/source", isDirectory: true),
      withIntermediateDirectories: true)
    try Data("imported".utf8).write(
      to: bundle.appendingPathComponent("rime/profiles/rime-ice/source/rime_ice.dict.yaml"))
    try FileManager.default.createDirectory(
      at: bundle.appendingPathComponent("rime/user/tracer.userdb", isDirectory: true),
      withIntermediateDirectories: true)
    let result = check()
    XCTAssertFalse(result.isClean)
    XCTAssertEqual(result.errors.filter { $0.path.contains("profiles") }.count, 1, result.report)
    XCTAssertEqual(result.errors.filter { $0.path.contains("user") }.count, 1, result.report)
  }

  /// A path that is not there is not "a bundle with no findings": without the guard this test was
  /// written for, the enumerator yielded nothing, the empty result became a warning, and `isClean` was
  /// true — a typo, or a build that produced nothing, would have passed the release check.
  func testABundleThatIsNotThereIsAnErrorRatherThanAWarning() {
    let missing = URL(fileURLWithPath: "/tmp/arkey-no-such-bundle-(UUID().uuidString).app")
    let result = RimeReleaseCheck.check(bundle: missing, tracerData: tracerData)
    XCTAssertFalse(result.isClean, "a missing bundle must not pass")
    XCTAssertEqual(result.errors.count, 1)
    XCTAssertTrue(result.errors[0].reason.contains("not there"), result.errors[0].reason)
    XCTAssertTrue(result.warnings.isEmpty, "it is not a warning: " + result.report)
  }

  func testABundleWithNoDataAtAllIsAWarningRatherThanACleanPass() throws {
    try FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    // The icon and the manifests are not what this test is about: it is about data, or the lack of it.
    try Data("icon".utf8).write(to: bundle.appendingPathComponent("AppIcon60x60@2x.png"))
    try Data("manifest".utf8).write(to: bundle.appendingPathComponent("PrivacyInfo.xcprivacy"))
    let plugin = bundle.appendingPathComponent("PlugIns/ARKeyboard.appex", isDirectory: true)
    try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
    try Data("manifest".utf8).write(to: plugin.appendingPathComponent("PrivacyInfo.xcprivacy"))
    let result = check()
    XCTAssertTrue(result.errors.isEmpty)
    XCTAssertFalse(result.warnings.isEmpty)
    XCTAssertEqual(result.dataDirectories, [])
  }
}
