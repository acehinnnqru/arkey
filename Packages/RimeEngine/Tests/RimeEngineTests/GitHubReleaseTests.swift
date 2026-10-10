import XCTest
@testable import RimeEngine

final class GitHubReleaseTests: XCTestCase {
  private func release(_ tag: String, published: String = "2026-01-01T00:00:00Z",
                       prerelease: Bool = false, draft: Bool = false,
                       asset: String = "full.zip") -> String {
    """
    {"tag_name":"\(tag)","html_url":"https://github.com/iDvel/rime-ice/releases/tag/\(tag)",
     "published_at":"\(published)","draft":\(draft),"prerelease":\(prerelease),"body":"notes",
     "assets":[{"id":123,"name":"\(asset)","size":4096,"updated_at":"\(published)",
     "browser_download_url":"https://github.com/iDvel/rime-ice/releases/download/\(tag)/\(asset)"}]}
    """
  }

  func testStableExcludesNightlyEvenWhenGitHubMarksItAsARelease() throws {
    let data = Data(("[" + [
      release("nightly", published: "2026-10-10T00:00:00Z"),
      release("preview", published: "2026-10-09T00:00:00Z", prerelease: true),
      release("draft", published: "2026-10-08T00:00:00Z", draft: true),
      release("tools", published: "2026-10-07T00:00:00Z", asset: "tools.zip"),
      release("2026.06.30", published: "2026-06-30T00:00:00Z"),
      release("2026.06.03", published: "2026-06-03T00:00:00Z")
    ].joined(separator: ",") + "]").utf8)
    let selected = try XCTUnwrap(RimeGitHubRelease.select(from: data, channel: .stable))
    XCTAssertEqual(selected.tagName, "2026.06.30")
    XCTAssertEqual(selected.sourceArchive?.name, "full.zip")
    XCTAssertEqual(selected.sourceArchive?.id, 123)
  }

  func testNightlyUsesItsExplicitTagAndRequiresSources() throws {
    XCTAssertNotNil(try RimeGitHubRelease.select(from: Data(release("nightly").utf8), channel: .nightly))
    XCTAssertNil(try RimeGitHubRelease.select(from: Data(release("2026.06.30").utf8), channel: .nightly))
    XCTAssertNil(try RimeGitHubRelease.select(from: Data(release("nightly", asset: "full_compiled.zip").utf8), channel: .nightly))
    XCTAssertNil(try RimeGitHubRelease.select(from: Data("[]".utf8), channel: .stable))
  }

  func testURLsRejectCredentialsAndNonHTTPSAndConstrainPresetAssets() throws {
    for url in ["http://example.com/a.zip", "file:///a.zip", "https://user:password@example.com/a.zip", "garbage"] {
      XCTAssertThrowsError(try RimeDownloadURL.validate(url))
    }
    XCTAssertEqual(try RimeDownloadURL.validate(" https://example.com/archive?id=1 ").host, "example.com")
    XCTAssertNoThrow(try RimeDownloadURL.githubAsset("https://github.com/iDvel/rime-ice/releases/download/nightly/full.zip"))
    XCTAssertThrowsError(try RimeDownloadURL.githubAsset("https://example.com/full.zip"))
    XCTAssertThrowsError(try RimeDownloadURL.githubAsset("https://github.com/other/repo/releases/download/v1/full.zip"))
  }

  func testProfileIdentityUsesContentInsteadOfTheDigestPrefix() {
    let first = RimeProfileIdentifier.make(displayName: "Rime Ice", tag: "nightly", digest: "sha256:11111111aaaaaaaa")
    let second = RimeProfileIdentifier.make(displayName: "Rime Ice", tag: "nightly", digest: "sha256:22222222bbbbbbbb")
    XCTAssertNotEqual(first, second)
    XCTAssertTrue(first.hasSuffix("11111111aaaaaaaa"))
  }

  func testOlderSourceMetadataStillDecodes() throws {
    let source = try JSONDecoder().decode(RimeProfileSource.self, from: Data(#"{"kind":"download","url":"https://example.com/full.zip"}"#.utf8))
    XCTAssertNil(source.catalogEntryID)
    XCTAssertNil(source.releaseAssetID)
    XCTAssertNil(source.transformationVersion)
  }
}
