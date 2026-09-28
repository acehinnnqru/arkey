import XCTest
@testable import RimeEngine

/// S6's notices: what the 许可证 screen shows, and the one statement on it that a script enforces.
final class S6NoticesTests: XCTestCase {
  private var scratch: URL!
  private var workspace: RimeWorkspace!
  private var engine: RimeEngine!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s6-notices", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()
    engine = RimeEngine(configuration: RimeConfiguration(directories: RimeDirectories(
      sharedDataDir: scratch.path,
      prebuiltDataDir: scratch.path,
      userDataDir: workspace.userData.path,
      stagingDir: workspace.staging.path,
      logDir: workspace.log.path)))
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    try? FileManager.default.removeItem(at: scratch)
  }

  private func install(id: String, name: String, license: RimeProfileLicense?,
                       noticeFile: String? = nil, noticeContents: String? = nil) throws {
    let layout = workspace.profile(id)
    try FileManager.default.createDirectory(at: layout.source, withIntermediateDirectories: true)
    if let noticeFile, let noticeContents {
      let url = layout.source.appendingPathComponent(noticeFile)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
      try Data(noticeContents.utf8).write(to: url)
    }
    var license = license
    if let noticeFile { license?.noticePath = noticeFile }
    try workspace.writeMetadata(RimeProfileMetadata(
      id: id, displayName: name,
      source: RimeProfileSource(kind: .download,
                                url: "https://example.invalid/arkey/rime-ice.zip",
                                resolvedURL: "https://github.com/iDvel/rime-ice/releases/download/nightly/full.zip",
                                releaseTag: "nightly"),
      license: license))
  }

  private func notices(bundleThirdParty: Bool = false) -> RimeNotices {
    RimeNoticesBuilder.build(workspace: workspace, engine: engine,
                             bundleContainsThirdPartyData: bundleThirdParty)
  }

  func testAFreshInstallSaysNothingThirdPartyIsPresent() {
    let text = notices().text
    XCTAssertTrue(text.contains("未安装任何第三方配置"), text)
    XCTAssertTrue(text.contains("本发布包中不含任何第三方配置数据"), text)
    XCTAssertTrue(text.contains("librime"), "the engine's own licence is stated")
    XCTAssertTrue(text.contains("BSD-3-Clause"))
    XCTAssertTrue(notices().isEmpty)
  }

  func testAProfileWithALicenceAndANoticeFileIsRenderedInFull() throws {
    try install(id: "rime-ice-nightly-abcd1234", name: "雾凇拼音",
                license: RimeProfileLicense(spdx: "GPL-3.0-only",
                                            name: "GNU General Public License v3.0",
                                            url: "https://www.gnu.org/licenses/gpl-3.0.html",
                                            sourceURL: "https://github.com/iDvel/rime-ice"),
                noticeFile: "others/docs/Credits.md",
                noticeContents: "# Credits\n")

    let entries = notices().entries
    XCTAssertEqual(entries.count, 1)
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entry.displayName, "雾凇拼音")
    XCTAssertEqual(entry.licenseLine, "GPL-3.0-only (GNU General Public License v3.0)")
    XCTAssertTrue(entry.noticeExists)
    XCTAssertTrue(entry.provenanceLine.contains("nightly"), entry.provenanceLine)
    XCTAssertTrue(entry.provenanceLine.contains("github.com/iDvel/rime-ice"), entry.provenanceLine)

    let text = notices().text
    XCTAssertTrue(text.contains("雾凇拼音"), text)
    XCTAssertTrue(text.contains("GPL-3.0-only"), text)
    XCTAssertTrue(text.contains("others/docs/Credits.md"), text)
    XCTAssertFalse(text.contains("文件中未找到"), "the file is there, so nothing is missing")
  }

  func testANoticePathThatDoesNotResolveIsCalledOut() throws {
    try install(id: "x", name: "X", license: RimeProfileLicense(spdx: "MIT", name: "MIT"),
                noticeFile: "CREDITS.md", noticeContents: nil)
    XCTAssertFalse(try XCTUnwrap(notices().entries.first).noticeExists)
    XCTAssertTrue(notices().text.contains("文件中未找到"), notices().text)
  }

  func testAProfileWithNoLicenceIsNoAssertionRatherThanPermissive() throws {
    try install(id: "y", name: "Y", license: nil)
    let entry = try XCTUnwrap(notices().entries.first)
    XCTAssertEqual(entry.license.spdx, "NOASSERTION")
    XCTAssertEqual(entry.licenseLine, "NOASSERTION (Unknown)")
    XCTAssertTrue(notices().text.contains("NOASSERTION"))
  }

  func testTheBundleStatementComesFromTheReleaseCheck() throws {
    try install(id: "z", name: "Z", license: .unknown)
    let clean = notices(bundleThirdParty: false).text
    XCTAssertTrue(clean.contains("本发布包中不含任何第三方配置数据"))
    let dirty = notices(bundleThirdParty: true).text
    XCTAssertTrue(dirty.contains("警告：发布包中检测到非本项目的配置数据"), dirty)
  }

  func testEntriesAreSortedForAReadableScreen() throws {
    try install(id: "b", name: "Zulu", license: .unknown)
    try install(id: "a", name: "Alpha", license: .unknown)
    XCTAssertEqual(notices().entries.map(\.displayName), ["Alpha", "Zulu"])
  }
}
