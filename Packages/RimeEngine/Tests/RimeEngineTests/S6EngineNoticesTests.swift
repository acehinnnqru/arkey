import XCTest
@testable import RimeEngine

/// S6-AC4: the notices name librime and what the pinned build contains, and never assert a licence
/// nobody has read.
final class S6EngineNoticesTests: XCTestCase {
  func testTheEngineComponentsAreListedWithTheirHomepages() {
    let components = RimeEngineNotices.components()
    XCTAssertGreaterThanOrEqual(components.count, 5)
    XCTAssertEqual(components.first?.name, "librime")
    for component in components {
      XCTAssertFalse(component.name.isEmpty)
      XCTAssertTrue(component.url.hasPrefix("https://"), component.name)
      XCTAssertFalse(component.line.isEmpty)
    }
    XCTAssertEqual(Set(components.map(\.name)).count, components.count, "no duplicates")
  }

  /// The verified licences are the two the pinned framework's own headers state; everything else is
  /// deliberately unsaid rather than guessed.
  func testOnlyVerifiedLicencesAreStated() {
    let components = RimeEngineNotices.components()
    let stated = components.filter { $0.license != nil }
    XCTAssertEqual(Set(stated.map(\.name)), ["librime", "librime-xcframework"])
    XCTAssertTrue(stated.allSatisfy { $0.license == "BSD-3-Clause" })

    let unverified = RimeEngineNotices.unverifiedLicenses()
    XCTAssertEqual(Set(unverified), ["librime-lua", "octagram", "predict"])
    for component in components where component.license == nil {
      XCTAssertTrue(component.line.contains("许可证见上游"), component.line)
    }
  }

  func testTheNoticesTextNamesTheEngineAndItsComponents() {
    let workspace = RimeWorkspace(root: FileManager.default.temporaryDirectory
      .appendingPathComponent("notices-\(UUID().uuidString)", isDirectory: true))
    let engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: workspace.root.path, prebuiltDataDir: workspace.root.path,
      userDataDir: workspace.userData.path, stagingDir: workspace.staging.path,
      logDir: workspace.log.path)))
    let text = RimeNoticesBuilder.build(workspace: workspace, engine: engine).text
    XCTAssertTrue(text.contains("librime"), text)
    XCTAssertTrue(text.contains("BSD-3-Clause"))
    XCTAssertTrue(text.contains("librime-lua"))
    XCTAssertTrue(text.contains("octagram"))
    XCTAssertTrue(text.contains("许可证见上游"))
    engine.shutdown()
  }

  /// The version on the licence screen has to be the version the package pins. A dependency bump that leaves
  /// this string behind would put a false statement in the one place a user goes to check, and the pinned
  /// version is in a repository file, so it can be compared rather than trusted.
  func testTheNoticesVersionIsTheVersionThePackagePins() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    // `root` is the Packages directory: four levels up from this file.
    let manifest = try String(contentsOf: root.appendingPathComponent("RimeEngine/Package.swift"),
                              encoding: .utf8)
    let pin = try XCTUnwrap(Self.pinnedVersion(in: manifest),
                            "librime-xcframework is not pinned in Package.swift any more")
    let notice = try XCTUnwrap(RimeEngineNotices.components().first { $0.name == "librime-xcframework" })
    XCTAssertEqual(notice.version, pin, "the notices name the pinned packaging version")
  }

  /// The linked engine answers for itself: the version we were compiled against is the version the notices
  /// print, so the two cannot drift apart on the screen.
  func testTheNoticesVersionIsTheEngineTheBinaryLinks() throws {
    let notice = try XCTUnwrap(RimeEngineNotices.components().first { $0.name == "librime" })
    XCTAssertEqual(notice.version, RimeEngine.librimeVersion)
    XCTAssertEqual(notice.version, RimeEngineVersion.pinned)
  }

  /// An unverified licence must say so where the user reads it: the line falls back to "许可证见上游", and the
  /// note repeats where to look. An invented SPDX identifier is the failure this guards against.
  func testAnUnverifiedLicenceSaysWhereToLookInsteadOfGuessing() throws {
    let unverified = RimeEngineNotices.components().filter { $0.license == nil }
    XCTAssertFalse(unverified.isEmpty, "three merged plugins are listed this way today")
    for component in unverified {
      XCTAssertTrue(component.line.contains("许可证见上游"), component.line)
      XCTAssertTrue(component.url.hasPrefix("https://"), component.url)
      XCTAssertNotNil(component.note, component.name + " is listed without a note")
    }
  }

  /// `.package(url: "…", exact: "1.2.3")` — the pin is read rather than assumed.
  private static func pinnedVersion(in manifest: String) -> String? {
    for line in manifest.split(separator: "\n") where line.contains("librime-xcframework") {
      guard let range = line.range(of: "exact:") else { continue }
      let rest = line[range.upperBound...]
      guard let open = rest.firstIndex(of: "\""),
            let close = rest[rest.index(after: open)...].firstIndex(of: "\"") else { continue }
      return String(rest[rest.index(after: open)..<close])
    }
    return nil
  }
}
