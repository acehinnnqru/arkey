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

  func testABundleWithNoDataAtAllIsAWarningRatherThanACleanPass() throws {
    try FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let result = check()
    XCTAssertTrue(result.errors.isEmpty)
    XCTAssertFalse(result.warnings.isEmpty)
    XCTAssertEqual(result.dataDirectories, [])
  }
}
